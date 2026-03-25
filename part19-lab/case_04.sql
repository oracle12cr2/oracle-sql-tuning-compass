-- =============================================================================
-- Case 04: JPPD (Join Predicate Push Down) 활용
-- 핵심 튜닝 기법: 인라인뷰/UNION ALL VIEW로 조건 침투시켜 불필요한 데이터 제거
-- 관련 단원: JOIN PREDICATE PUSH DOWN
-- 공통 데이터 세트: T_CUSTOMER + T_ORDER 테이블 사용
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
       (SELECT COUNT(*) FROM T_CUSTOMER) AS CUSTOMER_건수,
       (SELECT COUNT(*) FROM T_ORDER) AS ORDER_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. JPPD (Join Predicate Push Down) 시나리오 설명
PROMPT ========================================

/*
JPPD (Join Predicate Push Down) 개념:
- 인라인뷰 안으로 조건을 "밀어넣어" 불필요한 데이터 제거
- GROUP BY나 DISTINCT가 있는 인라인뷰에서 특히 효과적
- 메모리 사용량 감소 및 처리 속도 향상

시나리오: 고객별 주문 통계를 구하되, 특정 지역 고객만 조회
문제점: 인라인뷰에서 전체 고객 집계 후 필터링 → 불필요한 연산
해결책: JPPD로 조건을 인라인뷰 안으로 침투시켜 처리 범위 축소
*/

PROMPT
PROMPT ========================================
PROMPT 2. 데이터 분포 및 JPPD 조건 확인
PROMPT ========================================

-- 지역별 고객 분포 확인
SELECT region, COUNT(*) AS 고객수
FROM T_CUSTOMER
WHERE region IN ('R01', 'R02', 'R03', 'R04', 'R05')
GROUP BY region
ORDER BY region;

-- 고객별 주문 분포 (샘플링)
SELECT 
    '전체 고객' AS 구분, COUNT(DISTINCT cust_id) AS 고객수
FROM T_ORDER
UNION ALL
SELECT 
    '주문있는 고객', COUNT(DISTINCT cust_id)
FROM T_ORDER
WHERE cust_id <= 10000;  -- 샘플링

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (JPPD 없음)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_REGION VARCHAR2(10);
VARIABLE B_GRADE VARCHAR2(10);
EXEC :B_REGION := 'R01';
EXEC :B_GRADE := 'VIP';

-- 튜닝 전 SQL (JPPD 없음 - 비효율)
-- 인라인뷰에서 전체 고객의 주문 통계를 먼저 계산 후 필터링
SELECT 
    c.cust_id,
    c.cust_name,
    c.region,
    c.grade,
    order_stats.주문건수,
    order_stats.총주문금액,
    order_stats.평균주문금액,
    order_stats.최근주문일자
FROM T_CUSTOMER c,
     (SELECT 
          cust_id,
          COUNT(*) AS 주문건수,
          SUM(total_amount) AS 총주문금액,
          AVG(total_amount) AS 평균주문금액,
          MAX(order_date) AS 최근주문일자
      FROM T_ORDER
      WHERE status = 'COMPLETE'
      GROUP BY cust_id
      HAVING COUNT(*) >= 3) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region = :B_REGION
  AND c.grade = :B_GRADE
ORDER BY order_stats.총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (JPPD 적용)
PROMPT ========================================

-- 튜닝 후 SQL (JPPD 적용)
-- 인라인뷰 안으로 고객 조건이 침투하여 처리 범위 축소
SELECT 
    c.cust_id,
    c.cust_name,
    c.region,
    c.grade,
    order_stats.주문건수,
    order_stats.총주문금액,
    order_stats.평균주문금액,
    order_stats.최근주문일자
FROM T_CUSTOMER c,
     (SELECT /*+ PUSH_PRED */
          o.cust_id,
          COUNT(*) AS 주문건수,
          SUM(o.total_amount) AS 총주문금액,
          AVG(o.total_amount) AS 평균주문금액,
          MAX(o.order_date) AS 최근주문일자
      FROM T_ORDER o
      WHERE o.status = 'COMPLETE'
      GROUP BY o.cust_id
      HAVING COUNT(*) >= 3) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region = :B_REGION
  AND c.grade = :B_GRADE
ORDER BY order_stats.총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 5. JPPD 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. JPPD 동작 원리:
   - 외부 쿼리의 조건(c.region = :B_REGION)이 인라인뷰로 침투
   - 인라인뷰에서 해당 지역 고객의 주문만 GROUP BY 처리
   - 전체 처리 데이터량 대폭 감소

2. JPPD 적용 조건:
   - 인라인뷰에 GROUP BY, DISTINCT 등 집계 연산 존재
   - 외부 쿼리에 선택성 좋은 조건 존재
   - 인라인뷰와 외부 테이블이 조인 키로 연결

3. JPPD 발생 방법:
   - 자동: CBO가 비용 효율적이라고 판단
   - 수동: PUSH_PRED 힌트 사용
   - 금지: NO_PUSH_PRED 힌트 사용

4. 성과:
   - PGA 메모리 사용량 감소 (Hash Group By 범위 축소)
   - CPU 연산량 감소 (집계 대상 데이터 감소)
   - 실행 시간 단축

5. 실행계획 확인 포인트:
   - "PUSHED PREDICATE" 표시 확인
   - 인라인뷰 Cardinality 감소 확인
   - Hash Group By 메모리 사용량 비교
*/

-- JPPD 효과 비교를 위한 추가 테스트
PROMPT
PROMPT === JPPD 효과 비교 ===

-- 1) JPPD 금지 (NO_PUSH_PRED)
SELECT /*+ NO_PUSH_PRED */
    COUNT(*) AS 결과건수,
    SUM(order_stats.총주문금액) AS 총액
FROM T_CUSTOMER c,
     (SELECT 
          cust_id,
          COUNT(*) AS 주문건수,
          SUM(total_amount) AS 총주문금액
      FROM T_ORDER
      WHERE status = 'COMPLETE' 
      GROUP BY cust_id
      HAVING COUNT(*) >= 2) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region IN ('R01', 'R02');

-- 2) JPPD 강제 적용 (PUSH_PRED)
SELECT /*+ PUSH_PRED */
    COUNT(*) AS 결과건수,
    SUM(order_stats.총주문금액) AS 총액
FROM T_CUSTOMER c,
     (SELECT 
          o.cust_id,
          COUNT(*) AS 주문건수,
          SUM(o.total_amount) AS 총주문금액
      FROM T_ORDER o
      WHERE o.status = 'COMPLETE'
      GROUP BY o.cust_id  
      HAVING COUNT(*) >= 2) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region IN ('R01', 'R02');

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
JPPD 실무 활용 가이드:

✅ JPPD 적용 권장 상황:
- 인라인뷰에 GROUP BY/DISTINCT/집계함수 있는 경우
- 외부 테이블에 선택성 좋은 필터 조건 존재
- 인라인뷰 처리 데이터가 전체 대비 많은 경우
- PGA 메모리 부족으로 Temp 공간 사용하는 경우

❌ JPPD 적용 주의:
- 인라인뷰 결과가 이미 충분히 작은 경우
- 외부 조건의 선택성이 나쁜 경우 (거의 전체 데이터)
- 복잡한 서브쿼리로 인한 실행계획 불안정

🔧 JPPD 튜닝 체크리스트:
1. 실행계획에서 "PUSHED PREDICATE" 확인
2. 인라인뷰 Cardinality(A-Rows) 감소 확인
3. Hash Group By 메모리 사용량 비교
4. 전체 실행시간 및 논리적 I/O 비교
5. PGA 사용량 모니터링 (v$sesstat)

📊 성능 측정 지표:
- 인라인뷰 처리 Row 수 (A-Rows)
- Hash Group By 시간/메모리
- 전체 Consistent Gets
- PGA 최대 사용량
*/

-- JPPD 효과 정량 측정
PROMPT  
PROMPT === JPPD 정량 효과 측정 ===

-- 처리 데이터량 비교 (인라인뷰별)
WITH no_jppd_stats AS (
    -- 전체 고객 대상 집계 후 필터링
    SELECT COUNT(DISTINCT cust_id) AS processed_custs
    FROM T_ORDER 
    WHERE status = 'COMPLETE'
), jppd_stats AS (
    -- 특정 지역 고객만 집계 (JPPD 시뮬레이션)
    SELECT COUNT(DISTINCT o.cust_id) AS processed_custs
    FROM T_ORDER o, T_CUSTOMER c
    WHERE o.cust_id = c.cust_id
      AND o.status = 'COMPLETE'
      AND c.region = 'R01'
)
SELECT 
    nj.processed_custs AS JPPD없음_처리고객수,
    js.processed_custs AS JPPD적용_처리고객수,
    ROUND((nj.processed_custs - js.processed_custs) * 100.0 / nj.processed_custs, 2) AS 감소율_PCT
FROM no_jppd_stats nj, jppd_stats js;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH before_jppd AS (
    SELECT /*+ NO_PUSH_PRED */ COUNT(*) AS cnt, SUM(order_stats.총주문금액) AS sum_amt
    FROM T_CUSTOMER c,
         (SELECT cust_id, SUM(total_amount) AS 총주문금액
          FROM T_ORDER WHERE status = 'COMPLETE' GROUP BY cust_id) order_stats
    WHERE c.cust_id = order_stats.cust_id AND c.region = :B_REGION AND c.grade = :B_GRADE
), after_jppd AS (
    SELECT /*+ PUSH_PRED */ COUNT(*) AS cnt, SUM(order_stats.총주문금액) AS sum_amt  
    FROM T_CUSTOMER c,
         (SELECT o.cust_id, SUM(o.total_amount) AS 총주문금액
          FROM T_ORDER o WHERE o.status = 'COMPLETE' GROUP BY o.cust_id) order_stats
    WHERE c.cust_id = order_stats.cust_id AND c.region = :B_REGION AND c.grade = :B_GRADE
)
SELECT 
    bj.cnt AS JPPD전_건수, aj.cnt AS JPPD후_건수,
    bj.sum_amt AS JPPD전_금액합계, aj.sum_amt AS JPPD후_금액합계,
    CASE WHEN bj.cnt = aj.cnt AND NVL(bj.sum_amt,0) = NVL(aj.sum_amt,0)
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM before_jppd bj, after_jppd aj;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 04 JPPD (Join Predicate Push Down) 실습 완료 ***
PROMPT *** 다음: case_05.sql (JOIN → 스칼라 서브쿼리) ***