# Part 19 튜닝 퀴즈 — 18문제

> 문제 SQL/실행계획 → 어떻게 튜닝? → 정답 확인
> 정답은 각 문제 아래 `<details>` 태그로 숨김

---

## 🟢 기본 (1~5)

### Q1. INDEX SKIP SCAN

테이블 T_ORDER에 인덱스 `IX_ORDER_N1 (REGION_CODE, ORDER_DATE, STORE_ID)` 가 있다.
아래 쿼리에서 REGION_CODE 조건이 없을 때 어떻게 인덱스를 활용할 수 있는가?

```sql
SELECT * FROM T_ORDER
 WHERE ORDER_DATE = '20260325'
   AND STORE_ID = 'S001';
```

<details>
<summary>정답</summary>

**INDEX SKIP SCAN 활용**

```sql
SELECT /*+ INDEX_SS(T_ORDER IX_ORDER_N1) */ * 
  FROM T_ORDER
 WHERE ORDER_DATE = '20260325'
   AND STORE_ID = 'S001';
```

선두 컬럼(REGION_CODE)의 NDV(고유값 수)가 적으면 INDEX SKIP SCAN이 효과적.
NDV가 크면 FULL SCAN보다 느릴 수 있으므로 주의.
→ 사례 01 참고
</details>

---

### Q2. JOIN 방식 변경

대량 테이블 A(100만건)와 B(50만건)를 NL JOIN하는데 67초 걸린다.
A에서 조건으로 필터링하면 10만건 남고, B는 그대로 50만건이다.
어떻게 개선?

<details>
<summary>정답</summary>

**NL JOIN → HASH JOIN 변경**

```sql
SELECT /*+ USE_HASH(B) */ ...
  FROM A, B
 WHERE A.key = B.key
   AND A.condition = 'value';
```

대량 데이터 간 JOIN은 HASH JOIN이 유리.
NL JOIN은 소량(Driving) × 대량(Inner) 패턴에서만 효과적.
→ 사례 03 참고
</details>

---

### Q3. Buffer Cache Hit Ratio

아래 결과에서 문제점과 조치는?

```
session logical reads: 1,000,000
physical reads:           150,000
Buffer Cache Hit %:         85%
```

<details>
<summary>정답</summary>

**Buffer Cache Hit 85%는 매우 낮음 (목표 99%+)**

원인 분석:
1. Full Table Scan이 많은 SQL 확인 → 인덱스 튜닝
2. Buffer Cache(DB_CACHE_SIZE) 크기 부족 → SGA 증설 검토
3. Top SQL의 DISK_READS 확인 → 비효율 SQL 튜닝

```sql
SELECT SQL_ID, DISK_READS, BUFFER_GETS
  FROM V$SQL
 ORDER BY DISK_READS DESC
 FETCH FIRST 10 ROWS ONLY;
```
→ Part 18 Section 02 참고
</details>

---

### Q4. UNION → CASE WHEN

아래 SQL의 문제점은? 어떻게 개선?

```sql
SELECT '매출' AS TYPE, SUM(AMOUNT) FROM T_SALES WHERE SALE_TYPE = 'A'
UNION ALL
SELECT '반품' AS TYPE, SUM(AMOUNT) FROM T_SALES WHERE SALE_TYPE = 'B'
UNION ALL
SELECT '교환' AS TYPE, SUM(AMOUNT) FROM T_SALES WHERE SALE_TYPE = 'C';
```

<details>
<summary>정답</summary>

**T_SALES를 3번 반복 스캔** → CASE WHEN으로 1회 스캔 통합

```sql
SELECT CASE SALE_TYPE WHEN 'A' THEN '매출' WHEN 'B' THEN '반품' WHEN 'C' THEN '교환' END AS TYPE,
       SUM(AMOUNT)
  FROM T_SALES
 WHERE SALE_TYPE IN ('A','B','C')
 GROUP BY SALE_TYPE;
```

동일 테이블에 대한 UNION은 반복 ACCESS.
CASE WHEN으로 1회 스캔으로 통합 가능.
→ 사례 11 참고
</details>

---

### Q5. 소프트 파싱

아래 PL/SQL의 성능 문제는?

```sql
BEGIN
  FOR i IN 1..10000 LOOP
    EXECUTE IMMEDIATE 'SELECT * FROM EMP WHERE EMPNO = ' || i;
  END LOOP;
END;
```

<details>
<summary>정답</summary>

**리터럴 SQL → 하드 파싱 10,000회 발생**

바인드 변수로 변경하여 소프트 파싱 유도:

```sql
BEGIN
  FOR i IN 1..10000 LOOP
    EXECUTE IMMEDIATE 'SELECT * FROM EMP WHERE EMPNO = :b1' USING i;
  END LOOP;
END;
```

하드 파싱: CPU 소모 + shared pool latch 경합 + library cache lock.
Soft Parse % 95%+ 유지가 목표.
→ Part 18 Section 02/04 참고
</details>

---

## 🟡 중급 (6~13)

### Q6. JPPD (Join Predicate Push Down)

인라인뷰가 GROUP BY를 포함하여 뷰 머징이 안 될 때, 인라인뷰 안으로 조건을 밀어넣는 방법은?

```sql
SELECT a.*, b.total_amt
  FROM T_CUSTOMER a,
       (SELECT cust_id, SUM(amount) total_amt
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.region = 'SEOUL';
```

<details>
<summary>정답</summary>

**JPPD (NO_MERGE + PUSH_PRED) 적용**

```sql
SELECT a.*, b.total_amt
  FROM T_CUSTOMER a,
       (SELECT /*+ NO_MERGE PUSH_PRED */ cust_id, SUM(amount) total_amt
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.region = 'SEOUL';
```

JPPD로 a.cust_id 조건이 인라인뷰 안으로 침투 →
전체 GROUP BY 대신 해당 cust_id만 집계.
T_ORDER에 cust_id 인덱스가 있어야 효과적.
→ 사례 04, 09, 15 참고
</details>

---

### Q7. 스칼라 서브쿼리 변환

아래 쿼리에서 T_CODE 테이블을 3번 반복 조인하고 있다. 개선 방법은?

```sql
SELECT a.order_id, a.code1, b.code_name, a.code2, c.code_name, a.code3, d.code_name
  FROM T_ORDER a
  JOIN T_CODE b ON a.code1 = b.code
  JOIN T_CODE c ON a.code2 = c.code
  JOIN T_CODE d ON a.code3 = d.code
 WHERE a.order_date = '20260325';
```

<details>
<summary>정답</summary>

**JOIN → 스칼라 서브쿼리 변환** (코드 테이블처럼 NDV가 적은 경우)

```sql
SELECT a.order_id, a.code1,
       (SELECT code_name FROM T_CODE WHERE code = a.code1) AS name1,
       a.code2,
       (SELECT code_name FROM T_CODE WHERE code = a.code2) AS name2,
       a.code3,
       (SELECT code_name FROM T_CODE WHERE code = a.code3) AS name3
  FROM T_ORDER a
 WHERE a.order_date = '20260325';
```

스칼라 서브쿼리는 **캐싱** 효과로 동일 입력값은 재실행 없음.
코드 테이블(NDV 적음)에 효과적. 대량 테이블에는 비효율.
→ 사례 05 참고
</details>

---

### Q8. EXISTS vs IN

대량 테이블에서 서브쿼리 필터링 시 IN과 EXISTS의 차이는?

```sql
-- 방식 1: IN
SELECT * FROM T_ORDER
 WHERE cust_id IN (SELECT cust_id FROM T_VIP WHERE grade = 'GOLD');

-- 방식 2: EXISTS
SELECT * FROM T_ORDER a
 WHERE EXISTS (SELECT 1 FROM T_VIP b WHERE b.cust_id = a.cust_id AND b.grade = 'GOLD');
```

<details>
<summary>정답</summary>

**상황에 따라 다름:**

- **T_VIP가 소량** → IN이 유리 (서브쿼리 먼저 실행, 결과를 T_ORDER에 적용)
- **T_ORDER 필터링 후 소량** → EXISTS가 유리 (메인 먼저, 건건이 확인)
- **옵티마이저가 SEMI JOIN으로 풀면** → 동일

핵심: EXISTS는 **먼저 필터링하는 쪽**이 건수가 적을 때 유리.
JOIN 순서를 제어하는 효과. LEADING 힌트와 조합 가능.
→ 사례 06 참고
</details>

---

### Q9. 페이징 후 JOIN

게시판 목록에서 100건만 보여주는데, JOIN을 모두 한 후 ROWNUM으로 자르고 있다.
어떻게 개선?

```sql
SELECT * FROM (
  SELECT a.*, b.dept_name, c.status_name,
         ROW_NUMBER() OVER(ORDER BY a.created_date DESC) rn
    FROM T_BOARD a
    JOIN T_DEPT b ON a.dept_id = b.dept_id
    JOIN T_STATUS c ON a.status = c.status_code
) WHERE rn BETWEEN 1 AND 20;
```

<details>
<summary>정답</summary>

**페이징 먼저, JOIN은 나중에** (스칼라 서브쿼리 활용)

```sql
SELECT a.*,
       (SELECT dept_name FROM T_DEPT WHERE dept_id = a.dept_id) AS dept_name,
       (SELECT status_name FROM T_STATUS WHERE status_code = a.status) AS status_name
  FROM (
    SELECT a.*, ROW_NUMBER() OVER(ORDER BY created_date DESC) rn
      FROM T_BOARD a
  ) a
 WHERE rn BETWEEN 1 AND 20;
```

20건만 추출한 후 스칼라 서브쿼리로 코드 변환 → JOIN 부하 최소화.
전체 데이터 JOIN 후 자르기 vs 자른 후 JOIN → 성능 차이 극대.
→ 사례 13 참고
</details>

---

### Q10. WAIT EVENT 분석

AWR에서 아래 결과가 나왔다. 원인과 조치는?

```
Top 5 Foreground Events:
  Event                          Waits    Time(s)  Avg(ms)
  db file sequential read       500,000   3,200     6.4
  latch: cache buffers chains    50,000   1,800    36.0
  buffer busy waits              30,000     900    30.0
  db file scattered read         20,000     400    20.0
  log file sync                  10,000     150    15.0
```

<details>
<summary>정답</summary>

**Hot Block 문제 (latch: cache buffers chains + buffer busy waits)**

1. `latch: cache buffers chains` 36ms — 동일 Block 동시 접근 경합
2. `buffer busy waits` 30ms — Hot Block 읽기/수정 경합
3. `log file sync` 15ms — 목표 10ms 초과, Redo Log 디스크 성능 점검

조치:
- ASH에서 해당 시간대 TOP SQL 확인 → 동일 Block 접근하는 SQL 튜닝
- HASH 파티셔닝으로 Hot Block 분산
- Redo Log를 빠른 디스크로 이동

```sql
SELECT SQL_ID, EVENT, COUNT(*) FROM V$ACTIVE_SESSION_HISTORY
 WHERE EVENT IN ('latch: cache buffers chains','buffer busy waits')
 GROUP BY SQL_ID, EVENT ORDER BY 3 DESC;
```
→ Part 18 Section 02/04 참고
</details>

---

### Q11. 실행 계획 분리

아래 쿼리에서 STATUS 값에 따라 최적 실행계획이 다르다.
STATUS='ACTIVE'는 소량(100건), STATUS='ALL'은 전체(100만건). 어떻게?

```sql
SELECT * FROM T_LOG
 WHERE (STATUS = :b_status OR :b_status = 'ALL')
   AND LOG_DATE BETWEEN :b_from AND :b_to;
```

<details>
<summary>정답</summary>

**UNION ALL로 실행 계획 분리**

```sql
SELECT * FROM T_LOG
 WHERE STATUS = :b_status
   AND :b_status <> 'ALL'
   AND LOG_DATE BETWEEN :b_from AND :b_to
UNION ALL
SELECT * FROM T_LOG
 WHERE :b_status = 'ALL'
   AND LOG_DATE BETWEEN :b_from AND :b_to;
```

첫 번째: STATUS 인덱스 활용 (소량)
두 번째: LOG_DATE 범위 스캔 (전체)

바인드 변수 값에 따라 다른 실행계획이 필요할 때 UNION ALL로 분리.
→ 사례 07 참고
</details>

---

### Q12. INDEX FULL SCAN (MIN/MAX)

아래 쿼리가 Full Table Scan + Sort를 하고 있다. 인덱스만으로 해결하려면?

```sql
SELECT MAX(order_date) FROM T_ORDER WHERE cust_id = 'C001';
```

인덱스: `IX_ORDER_N1 (CUST_ID, ORDER_DATE)`

<details>
<summary>정답</summary>

**INDEX RANGE SCAN (MIN/MAX)** — Sort 없이 인덱스 역순 1건만 읽기

```sql
SELECT /*+ INDEX_DESC(T_ORDER IX_ORDER_N1) */ order_date
  FROM T_ORDER
 WHERE cust_id = 'C001'
   AND order_date IS NOT NULL
   AND ROWNUM = 1;
```

또는 옵티마이저가 자동으로 FIRST ROW (MIN/MAX) 최적화.
인덱스가 (CUST_ID, ORDER_DATE) 순이면 역순 스캔 1건으로 끝.
→ 사례 12 참고
</details>

---

### Q13. DB_TIME 급증 분석 프로세스

DB_TIME이 평소 대비 5배 증가했다. 분석 순서는?

<details>
<summary>정답</summary>

**Top Down 분석 프로세스:**

```
① DB_TIME 증가 확인 (V$SYS_TIME_MODEL / AWR)
② DB_CPU도 같이 증가? 
   → YES: SQL 부하 증가 → ④로
   → NO: 대기 시간 증가 → ③으로
③ WAIT EVENT CLASS 분석 (어떤 대기가 증가?)
   → User I/O: 비효율 SQL → ④
   → Concurrency: Hot Block, Latch → 인프라/SQL 튜닝
   → Application: Lock 경합 → 트랜잭션 분석
   → Cluster: RAC 노드간 경합 → 서비스 분리
④ TOP SQL 분석 (ELAPSED_TIME 기준)
⑤ ASH 상세 분석 (1초 단위)
⑥ SQL 튜닝 또는 인프라 조치
```

핵심 공식: `DB_TIME = DB_CPU + Non-Idle Wait Time`
→ Part 18 Section 04 참고
</details>

---

## 🔴 고급 (14~18)

### Q14. JPPD로 GROUP BY 제거

아래 인라인뷰는 전체 T_ORDER를 GROUP BY하고 있다. 
메인 쿼리에서 특정 cust_id만 필요할 때 어떻게 최적화?

```sql
SELECT a.cust_name, b.order_cnt, b.total_amt
  FROM T_CUSTOMER a,
       (SELECT cust_id, COUNT(*) order_cnt, SUM(amount) total_amt
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.region = 'SEOUL'
   AND a.grade = 'VIP';
```

VIP+SEOUL 고객은 50명, T_ORDER는 1000만건.

<details>
<summary>정답</summary>

**JPPD로 인라인뷰 침투 — 전체 GROUP BY 제거**

```sql
SELECT a.cust_name, b.order_cnt, b.total_amt
  FROM T_CUSTOMER a,
       (SELECT /*+ NO_MERGE PUSH_PRED */ cust_id, COUNT(*) order_cnt, SUM(amount) total_amt
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.region = 'SEOUL'
   AND a.grade = 'VIP';
```

PUSH_PRED로 a.cust_id 조건이 인라인뷰 안으로 침투.
1000만건 전체 GROUP BY → 50명분만 INDEX 조회로 변경.
T_ORDER(CUST_ID) 인덱스 필수.
→ 사례 15 참고
</details>

---

### Q15. WINDOW 함수로 반복 ACCESS 제거

아래 쿼리는 동일 테이블을 자기 자신과 JOIN하여 이전 행 값을 가져온다. 개선 방법은?

```sql
SELECT a.log_date, a.value,
       (SELECT MAX(b.value) FROM T_LOG b 
         WHERE b.log_date < a.log_date
           AND b.category = a.category) AS prev_value
  FROM T_LOG a
 WHERE a.category = 'CPU'
   AND a.log_date BETWEEN '20260301' AND '20260325';
```

<details>
<summary>정답</summary>

**LAG 윈도우 함수로 자기 JOIN 제거**

```sql
SELECT log_date, value,
       LAG(value) OVER(PARTITION BY category ORDER BY log_date) AS prev_value
  FROM T_LOG
 WHERE category = 'CPU'
   AND log_date BETWEEN '20260301' AND '20260325';
```

스칼라 서브쿼리의 반복 ACCESS (행마다 서브쿼리 실행) 제거.
LAG/LEAD/ROW_NUMBER 등 분석함수 1회 스캔으로 해결.
→ 사례 10 참고
</details>

---

### Q16. 복합 튜닝 — JOIN 순서 + 서브쿼리

3개 테이블 JOIN에서 잘못된 JOIN 순서로 중간 결과가 폭발하고 있다.
A(1만) → B(100만) → C(10) 순서로 JOIN 중.
A 조건 필터 후 100건, C 조건 필터 후 3건.

```sql
SELECT a.*, b.detail, c.category_name
  FROM T_HEADER a, T_DETAIL b, T_CATEGORY c
 WHERE a.header_id = b.header_id
   AND b.cat_id = c.cat_id
   AND a.status = 'ACTIVE'
   AND c.cat_type = 'PREMIUM';
```

<details>
<summary>정답</summary>

**JOIN 순서 변경: C(소량) → A(필터 후 소량) → B**

```sql
SELECT /*+ LEADING(c a b) USE_NL(a) USE_NL(b) */ 
       a.*, b.detail, c.category_name
  FROM T_HEADER a, T_DETAIL b, T_CATEGORY c
 WHERE a.header_id = b.header_id
   AND b.cat_id = c.cat_id
   AND a.status = 'ACTIVE'
   AND c.cat_type = 'PREMIUM';
```

또는 EXISTS로 C를 먼저 필터:

```sql
SELECT a.*, b.detail,
       (SELECT category_name FROM T_CATEGORY WHERE cat_id = b.cat_id) AS category_name
  FROM T_HEADER a, T_DETAIL b
 WHERE a.header_id = b.header_id
   AND a.status = 'ACTIVE'
   AND EXISTS (SELECT 1 FROM T_CATEGORY c WHERE c.cat_id = b.cat_id AND c.cat_type = 'PREMIUM');
```

핵심: **가장 적은 결과를 만드는 테이블부터 Driving**.
→ 사례 06, 14, 16 참고
</details>

---

### Q17. AWR 구간 비교 분석

화요일 14:00~14:30 (정상)과 수요일 14:00~14:30 (장애) 구간을 비교하려 한다.
AWR로 어떻게 분석하는가?

<details>
<summary>정답</summary>

**AWR Diff Report 또는 수동 비교**

```sql
-- 1. 스냅샷 ID 확인
SELECT SNAP_ID, TO_CHAR(END_INTERVAL_TIME, 'MM-DD HH24:MI') 
  FROM DBA_HIST_SNAPSHOT
 WHERE END_INTERVAL_TIME BETWEEN 
       TO_DATE('20260324 1400', 'YYYYMMDD HH24MI') 
   AND TO_DATE('20260325 1430', 'YYYYMMDD HH24MI');

-- 2. AWR Diff Report (두 구간 비교)
@?/rdbms/admin/awrddrpt.sql

-- 3. 수동 비교: SQL 자원 사용량 DELTA 비교
SELECT SQL_ID,
       SUM(CASE WHEN SNAP_ID BETWEEN :정상_시작 AND :정상_끝 THEN ELAPSED_TIME_DELTA END) AS NORMAL_ELAPSED,
       SUM(CASE WHEN SNAP_ID BETWEEN :장애_시작 AND :장애_끝 THEN ELAPSED_TIME_DELTA END) AS ISSUE_ELAPSED
  FROM DBA_HIST_SQLSTAT
 WHERE SNAP_ID BETWEEN :정상_시작 AND :장애_끝
 GROUP BY SQL_ID
HAVING SUM(CASE WHEN SNAP_ID BETWEEN :장애_시작 AND :장애_끝 THEN ELAPSED_TIME_DELTA END) >
       SUM(CASE WHEN SNAP_ID BETWEEN :정상_시작 AND :정상_끝 THEN ELAPSED_TIME_DELTA END) * 3
 ORDER BY ISSUE_ELAPSED DESC;
```

정상 구간 대비 3배 이상 증가한 SQL이 원인 후보.
→ Part 18 Section 03/04 참고
</details>

---

### Q18. 종합 — 실행계획 읽기

아래 실행계획에서 문제점 3가지를 찾아라.

```
--------------------------------------------------------------
| Id | Operation                    | Rows  | Bytes | Cost  |
--------------------------------------------------------------
|  0 | SELECT STATEMENT             |       |       | 45682 |
|  1 |  SORT ORDER BY               | 50000 |  2M   | 45682 |
|  2 |   HASH JOIN                  | 50000 |  2M   | 44123 |
|  3 |    TABLE ACCESS FULL         |500000 | 15M   | 12000 |
|  4 |    TABLE ACCESS FULL         |100000 |  5M   |  8000 |
|  5 |   TABLE ACCESS BY INDEX ROWID|     1 |  30   |     2 |
|  6 |    INDEX UNIQUE SCAN         |     1 |       |     1 |
--------------------------------------------------------------
```

<details>
<summary>정답</summary>

**문제점 3가지:**

1. **Id 3: TABLE ACCESS FULL (500K건)** — 50만건 Full Scan. 필터 조건에 맞는 인덱스 없거나 비효율적.
   → 적절한 인덱스 생성 또는 파티셔닝 검토

2. **Id 1: SORT ORDER BY (50K건)** — 5만건 정렬은 PGA 부담.
   → ORDER BY 컬럼이 인덱스에 포함되면 정렬 제거 가능
   → 페이징 처리라면 ROWNUM으로 소량만 정렬

3. **Id 5-6은 정상이지만 Id 2의 HASH JOIN 결과가 50K건** — Driving 테이블 필터링이 부족.
   → 조건 추가로 중간 결과 줄이거나 JOIN 순서 변경

추가: Cost 45682는 전체 비용의 대부분이 Full Scan + Hash Join.
인덱스 튜닝으로 비용 90% 감소 가능.
</details>

---

## 채점 기준

| 정답 수 | 등급 |
|---------|------|
| 16~18 | 🏆 튜닝 고수 |
| 12~15 | 👍 실무 투입 가능 |
| 8~11 | 📚 복습 필요 |
| ~7 | 🔄 Part 18~19 재학습 |
