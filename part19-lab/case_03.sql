-- =============================================================================
-- Case 03: NL JOIN → HASH JOIN 변경  
-- 핵심 튜닝 기법: 대량 건수 NL JOIN을 HASH JOIN으로 변경하여 I/O 최적화
-- 관련 단원: JOIN 최적화
-- 공통 데이터 세트: T_ORDER + T_ORDER_DETAIL 테이블 사용
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분,
       (SELECT COUNT(*) FROM T_ORDER) AS ORDER_건수,
       (SELECT COUNT(*) FROM T_ORDER_DETAIL) AS ORDER_DETAIL_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. NL vs HASH JOIN 시나리오 설명
PROMPT ========================================

/*
시나리오: 주문과 주문상세 대량 JOIN 처리
테이블: T_ORDER (100만건) + T_ORDER_DETAIL (500만건)
문제점: NL JOIN 시 Inner 테이블 반복 ACCESS로 I/O 과부하
해결책: HASH JOIN으로 변경하여 한번에 BUILD & PROBE

JOIN 방법별 특성:
1) NL JOIN: Outer Row마다 Inner 테이블 INDEX ACCESS (1:M 관계에서 비효율)
2) HASH JOIN: 작은 테이블을 Hash Table로 만들고 큰 테이블을 Probe
3) SORT MERGE: 양쪽 테이블 정렬 후 JOIN (이미 정렬된 경우 유리)
*/

PROMPT
PROMPT ========================================  
PROMPT 2. JOIN 조건 및 데이터 분포 확인
PROMPT ========================================

-- JOIN 키 분포 확인
SELECT 'T_ORDER 건수' AS 구분, COUNT(*) AS 값 FROM T_ORDER
UNION ALL
SELECT 'T_ORDER_DETAIL 건수', COUNT(*) FROM T_ORDER_DETAIL
UNION ALL
SELECT 'JOIN 키 매칭 확인', COUNT(DISTINCT od.order_id) 
FROM T_ORDER_DETAIL od, T_ORDER o 
WHERE od.order_id = o.order_id
AND ROWNUM <= 100000;  -- 샘플링으로 확인

-- 주문당 상세 건수 분포 (JOIN Cardinality)
SELECT 
    '1건' AS 상세건수_범위,
    COUNT(*) AS 주문수
FROM (
    SELECT order_id, COUNT(*) AS detail_cnt
    FROM T_ORDER_DETAIL 
    WHERE order_id <= 10000  -- 샘플링
    GROUP BY order_id
    HAVING COUNT(*) = 1
)
UNION ALL
SELECT '2-5건', COUNT(*)
FROM (
    SELECT order_id, COUNT(*) AS detail_cnt  
    FROM T_ORDER_DETAIL
    WHERE order_id <= 10000
    GROUP BY order_id
    HAVING COUNT(*) BETWEEN 2 AND 5
)
UNION ALL
SELECT '6건이상', COUNT(*)
FROM (
    SELECT order_id, COUNT(*) AS detail_cnt
    FROM T_ORDER_DETAIL  
    WHERE order_id <= 10000
    GROUP BY order_id
    HAVING COUNT(*) >= 6
);

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (NL JOIN)
PROMPT ========================================

-- 바인드 변수 설정  
VARIABLE B_START_DATE DATE;
VARIABLE B_END_DATE DATE;
VARIABLE B_STATUS VARCHAR2(20);
EXEC :B_START_DATE := DATE '2024-06-01';
EXEC :B_END_DATE := DATE '2024-06-30'; 
EXEC :B_STATUS := 'COMPLETE';

-- 튜닝 전 SQL (NL JOIN 강제 - 비효율)
-- 대량 데이터에서 NL JOIN은 Inner 테이블 반복 ACCESS 발생
SELECT /*+ USE_NL(o od) LEADING(o od) */
    o.order_id,
    o.cust_id,
    o.order_date,
    o.status,
    COUNT(od.detail_id) AS 상세건수,
    SUM(od.amount) AS 총주문금액,
    AVG(od.unit_price) AS 평균단가
FROM T_ORDER o,
     T_ORDER_DETAIL od  
WHERE o.order_id = od.order_id
  AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND o.status = :B_STATUS
GROUP BY o.order_id, o.cust_id, o.order_date, o.status
HAVING SUM(od.amount) > 50000
ORDER BY 총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (HASH JOIN)
PROMPT ========================================

-- 튜닝 후 SQL (HASH JOIN 사용)
-- 대량 JOIN에 최적화된 HASH JOIN으로 I/O 최적화
SELECT /*+ USE_HASH(o od) LEADING(o od) */
    o.order_id,
    o.cust_id,
    o.order_date, 
    o.status,
    COUNT(od.detail_id) AS 상세건수,
    SUM(od.amount) AS 총주문금액,
    AVG(od.unit_price) AS 평균단가
FROM T_ORDER o,
     T_ORDER_DETAIL od
WHERE o.order_id = od.order_id
  AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND o.status = :B_STATUS  
GROUP BY o.order_id, o.cust_id, o.order_date, o.status
HAVING SUM(od.amount) > 50000
ORDER BY 총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 5. JOIN 방법 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. NL JOIN 문제점:
   - Outer 테이블(T_ORDER) 각 Row마다 Inner 테이블 INDEX SEEK
   - T_ORDER 10만 Row → T_ORDER_DETAIL INDEX ACCESS 10만번
   - 대량 데이터에서 Random I/O 과다 발생
   - Buffer Cache 효율성 저하

2. HASH JOIN 장점:
   - 작은 테이블(T_ORDER)을 Hash Table로 BUILD
   - 큰 테이블(T_ORDER_DETAIL)을 순차 SCAN하며 PROBE
   - Sequential I/O 위주로 처리
   - JOIN 키 Hash값으로 빠른 매칭

3. HASH JOIN 적용 조건:
   - 조인 결과가 전체 데이터의 일정 비율 이상
   - 한쪽 테이블이 PGA Hash Area에 들어갈 크기
   - Equi-Join (= 조건)인 경우
   - 통계 정보가 정확한 경우

4. 힌트 사용법:
   - USE_HASH(테이블1 테이블2): HASH JOIN 강제
   - LEADING(테이블1 테이블2): JOIN 순서 지정 (BUILD 테이블 먼저)
   - PQ_DISTRIBUTE(테이블 BROADCAST): Parallel 환경에서 분산 방법

5. 성과:
   - Consistent Gets 대폭 감소 (Random → Sequential I/O)
   - CPU 사용량 증가하나 전체 응답시간 단축
   - Buffer Pool 효율성 개선
*/

-- JOIN 방법별 성능 비교
PROMPT
PROMPT === JOIN 방법별 성능 비교 ===

-- 1) NL JOIN 강제
SELECT /*+ USE_NL(o od) LEADING(o od) */ 
    COUNT(*) AS 결과건수, 
    SUM(od.amount) AS 총액
FROM T_ORDER o, T_ORDER_DETAIL od
WHERE o.order_id = od.order_id  
  AND o.order_date >= DATE '2024-06-01'
  AND o.order_date < DATE '2024-07-01'
  AND o.status = 'COMPLETE';

-- 2) HASH JOIN 강제
SELECT /*+ USE_HASH(o od) LEADING(o od) */
    COUNT(*) AS 결과건수,
    SUM(od.amount) AS 총액  
FROM T_ORDER o, T_ORDER_DETAIL od
WHERE o.order_id = od.order_id
  AND o.order_date >= DATE '2024-06-01' 
  AND o.order_date < DATE '2024-07-01'
  AND o.status = 'COMPLETE';

-- 3) 옵티마이저 선택 (힌트 없음)
SELECT COUNT(*) AS 결과건수, 
       SUM(od.amount) AS 총액
FROM T_ORDER o, T_ORDER_DETAIL od
WHERE o.order_id = od.order_id
  AND o.order_date >= DATE '2024-06-01'
  AND o.order_date < DATE '2024-07-01'  
  AND o.status = 'COMPLETE';

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
JOIN 방법 선택 가이드:

🔹 NL JOIN 적용 상황:
- 조인 결과가 적은 경우 (< 전체 1%)
- Outer 테이블 조건으로 크게 필터링되는 경우
- Inner 테이블에 유용한 INDEX가 있는 경우  
- OLTP 환경의 단건/소량 처리

🔹 HASH JOIN 적용 상황:
- 대량 데이터 JOIN (조인 결과 > 전체 5%)
- 양쪽 테이블 모두 범위 조건인 경우
- Inner 테이블에 적절한 INDEX가 없는 경우
- 배치/DW 환경의 대량 처리

🔹 SORT MERGE JOIN 적용 상황:
- 양쪽 테이블이 이미 정렬되어 있는 경우
- 메모리가 부족해서 HASH JOIN이 어려운 경우
- 부등호 조인 조건 (>, <, BETWEEN)

❗ 주의사항:
- PGA 메모리 부족 시 HASH JOIN → Temp Tablespace 사용
- 통계 정보 부정확 시 잘못된 JOIN 방법 선택
- Parallel 처리 시 PQ_DISTRIBUTE 고려 필요

🔧 성능 튜닝 체크리스트:
1. JOIN 키에 INDEX 존재 여부 확인
2. 조인 Cardinality 확인 (1:1, 1:M, M:M)
3. 각 테이블의 필터 조건 효율성 확인
4. 실행계획에서 Rows, Buffers 비교
5. PGA/Temp 공간 사용량 모니터링
*/

-- JOIN 효율성 검증
PROMPT
PROMPT === JOIN 효율성 검증 ===

-- 실제 JOIN Cardinality 확인
WITH join_stats AS (
    SELECT 
        COUNT(DISTINCT o.order_id) AS distinct_orders,
        COUNT(DISTINCT od.detail_id) AS distinct_details,
        COUNT(*) AS total_joins
    FROM T_ORDER o, T_ORDER_DETAIL od
    WHERE o.order_id = od.order_id
      AND o.order_date >= DATE '2024-06-01'
      AND o.order_date < DATE '2024-07-01' 
      AND ROWNUM <= 50000  -- 샘플링
)
SELECT 
    distinct_orders AS 조인된_주문수,
    distinct_details AS 조인된_상세수, 
    total_joins AS 전체_조인결과,
    ROUND(total_joins / distinct_orders, 2) AS 주문당_평균상세건수
FROM join_stats;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH nl_join AS (
    SELECT /*+ USE_NL(o od) */ COUNT(*) AS cnt, SUM(od.amount) AS sum_amt
    FROM T_ORDER o, T_ORDER_DETAIL od
    WHERE o.order_id = od.order_id
      AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND o.status = :B_STATUS
), hash_join AS (
    SELECT /*+ USE_HASH(o od) */ COUNT(*) AS cnt, SUM(od.amount) AS sum_amt
    FROM T_ORDER o, T_ORDER_DETAIL od  
    WHERE o.order_id = od.order_id
      AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND o.status = :B_STATUS
)
SELECT 
    nl.cnt AS NL_JOIN_건수, hj.cnt AS HASH_JOIN_건수,
    nl.sum_amt AS NL_JOIN_금액합계, hj.sum_amt AS HASH_JOIN_금액합계,
    CASE WHEN nl.cnt = hj.cnt AND nl.sum_amt = hj.sum_amt 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM nl_join nl, hash_join hj;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 03 NL → HASH JOIN 변경 실습 완료 ***
PROMPT *** 다음: case_04.sql (JPPD 활용) ***