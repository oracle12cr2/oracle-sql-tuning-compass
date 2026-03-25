-- =============================================================================
-- Case 09: JPPD로 인라인뷰 침투 
-- 핵심 튜닝 기법: JOIN PREDICATE PUSH DOWN으로 PGA 사용량 최적화
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
PROMPT 1. JPPD 고급 시나리오 설명
PROMPT ========================================

/*
고급 JPPD 시나리오: 인라인뷰 침투로 PGA 최적화
- 대량 집계 처리 시 PGA 메모리 부족 문제 해결
- 외부 조건을 인라인뷰로 침투시켜 처리 범위 축소
- Hash Group By 메모리 사용량 최소화

시나리오: 지역별 고객 주문 통계
- 전체 고객(10만) 대상 주문 집계는 PGA 과다 사용
- 특정 지역 고객만 대상으로 축소하여 메모리 효율화
- PUSH_PRED로 강제 침투 또는 자동 최적화 활용
*/

PROMPT
PROMPT ========================================
PROMPT 2. PGA 사용량 및 데이터 분포 분석
PROMPT ========================================

-- 지역별 분포 (JPPD 효과 예상)
SELECT region, COUNT(*) AS 고객수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_CUSTOMER), 2) AS 고객비율_PCT
FROM T_CUSTOMER  
WHERE region IN ('R01', 'R02', 'R03', 'R04', 'R05')
GROUP BY region
ORDER BY COUNT(*) DESC;

-- 고객별 주문 분포 (집계 부하 확인)
SELECT 
    주문건수_범위,
    COUNT(*) AS 고객수,
    SUM(주문건수) AS 총주문건수
FROM (
    SELECT 
        cust_id,
        COUNT(*) AS 주문건수,
        CASE WHEN COUNT(*) = 1 THEN '1건'
             WHEN COUNT(*) BETWEEN 2 AND 5 THEN '2-5건'  
             WHEN COUNT(*) BETWEEN 6 AND 20 THEN '6-20건'
             ELSE '21건이상' END AS 주문건수_범위
    FROM T_ORDER
    WHERE cust_id <= 20000  -- 샘플링
    GROUP BY cust_id
)
GROUP BY 주문건수_범위
ORDER BY 
    CASE 주문건수_범위 
        WHEN '1건' THEN 1 WHEN '2-5건' THEN 2 
        WHEN '6-20건' THEN 3 ELSE 4 END;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (JPPD 없음)
PROMPT ========================================

-- 바인드 변수 설정  
VARIABLE B_REGION VARCHAR2(10);
VARIABLE B_MIN_AMOUNT NUMBER;
EXEC :B_REGION := 'R01';
EXEC :B_MIN_AMOUNT := 100000;

-- 튜닝 전 SQL (JPPD 없음)
-- 전체 고객 대상 집계 후 특정 지역만 필터링 → PGA 과다 사용
SELECT /*+ NO_PUSH_PRED */
    c.region,
    c.grade,
    COUNT(c.cust_id) AS 고객수,
    order_stats.총주문건수,
    order_stats.총주문금액,
    order_stats.평균주문금액,
    order_stats.최대주문금액
FROM T_CUSTOMER c,
     (SELECT 
          cust_id,
          COUNT(*) AS 총주문건수,
          SUM(total_amount) AS 총주문금액,
          AVG(total_amount) AS 평균주문금액,
          MAX(total_amount) AS 최대주문금액
      FROM T_ORDER
      WHERE status = 'COMPLETE'
        AND order_date >= DATE '2024-01-01'
      GROUP BY cust_id
      HAVING SUM(total_amount) > :B_MIN_AMOUNT) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region = :B_REGION
GROUP BY c.region, c.grade, order_stats.총주문건수, 
         order_stats.총주문금액, order_stats.평균주문금액, order_stats.최대주문금액
ORDER BY order_stats.총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (JPPD 적용)
PROMPT ========================================

-- 튜닝 후 SQL (JPPD 적용)  
-- 지역 조건이 인라인뷰로 침투하여 처리 범위 대폭 축소
SELECT /*+ PUSH_PRED */
    c.region,
    c.grade,
    COUNT(c.cust_id) AS 고객수,
    order_stats.총주문건수,
    order_stats.총주문금액,
    order_stats.평균주문금액,
    order_stats.최대주문금액
FROM T_CUSTOMER c,
     (SELECT 
          o.cust_id,
          COUNT(*) AS 총주문건수,
          SUM(o.total_amount) AS 총주문금액,
          AVG(o.total_amount) AS 평균주문금액,
          MAX(o.total_amount) AS 최대주문금액
      FROM T_ORDER o
      WHERE o.status = 'COMPLETE'
        AND o.order_date >= DATE '2024-01-01'
      GROUP BY o.cust_id
      HAVING SUM(o.total_amount) > :B_MIN_AMOUNT) order_stats
WHERE c.cust_id = order_stats.cust_id
  AND c.region = :B_REGION
GROUP BY c.region, c.grade, order_stats.총주문건수,
         order_stats.총주문금액, order_stats.평균주문금액, order_stats.최대주문금액
ORDER BY order_stats.총주문금액 DESC;

PROMPT
PROMPT ========================================
PROMPT 5. JPPD 고급 분석
PROMPT ========================================

/*
JPPD 고급 최적화 분석:

1. PGA 메모리 최적화:
   - Hash Group By 처리 범위 축소
   - 전체 고객(10만) → 특정 지역 고객(5천)  
   - PGA 사용량 95% 감소 효과

2. JPPD 침투 메커니즘:
   - c.region = :B_REGION 조건이 인라인뷰로 전파
   - 인라인뷰 내부: WHERE o.cust_id IN (특정지역고객IDs)
   - GROUP BY 처리 대상 데이터 대폭 감소

3. 자동 vs 수동 JPPD:
   - 자동: CBO가 비용 효율적 판단 시 적용
   - 수동: PUSH_PRED 힌트로 강제 적용
   - 금지: NO_PUSH_PRED 힌트로 차단

4. 실행계획 분석:
   - "PUSHED PREDICATE" 표시 확인
   - Hash Group By Cardinality 감소
   - 전체 처리 시간 단축

5. 부작용 주의:
   - 조건이 비선택적이면 오히려 비효율
   - 복잡한 조건 침투 시 실행계획 불안정
   - 통계 정보 정확성 중요
*/

-- JPPD 효과 정량 분석
PROMPT
PROMPT === JPPD 효과 정량 분석 ===

-- 처리 데이터량 비교
WITH jppd_effect AS (
    SELECT 
        (SELECT COUNT(DISTINCT cust_id) FROM T_ORDER 
         WHERE status = 'COMPLETE' AND order_date >= DATE '2024-01-01') AS without_jppd_customers,
        (SELECT COUNT(DISTINCT o.cust_id) FROM T_ORDER o, T_CUSTOMER c 
         WHERE o.cust_id = c.cust_id AND o.status = 'COMPLETE' 
         AND o.order_date >= DATE '2024-01-01' AND c.region = 'R01') AS with_jppd_customers
    FROM DUAL
)
SELECT 
    without_jppd_customers AS JPPD없음_처리고객수,
    with_jppd_customers AS JPPD적용_처리고객수,
    without_jppd_customers - with_jppd_customers AS 감소_고객수,
    ROUND((without_jppd_customers - with_jppd_customers) * 100.0 / without_jppd_customers, 2) AS 감소율_PCT
FROM jppd_effect;

PROMPT
PROMPT ========================================  
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
JPPD 실무 최적화 가이드:

✅ JPPD 적용 최적 시나리오:
- 대량 집계 쿼리 (GROUP BY, DISTINCT)
- 외부 테이블에 강한 선택 조건 존재  
- PGA 메모리 부족으로 TEMP 공간 사용
- 인라인뷰 처리량 > 외부 필터링 결과량

❌ JPPD 적용 주의 시나리오:
- 외부 조건의 선택성이 나쁜 경우
- 인라인뷰 결과가 이미 충분히 작은 경우
- 복잡한 조건으로 인한 실행계획 불안정

🔧 JPPD 최적화 체크리스트:
1. 실행계획에서 "PUSHED PREDICATE" 확인
2. Hash Group By 메모리 사용량 모니터링
3. 인라인뷰 Cardinality 감소 확인
4. PGA 사용량 측정 (v$sesstat, v$mystat)
5. Temp 공간 사용량 확인

📊 성능 측정 지표:
- PGA 최대 사용량 (PGA_AGGREGATE_TARGET 비교)
- Hash Group By 처리 시간
- Temp 공간 I/O (direct path read/write temp)
- 전체 실행 시간 개선도

💡 추가 최적화 기법:
- Parallel 처리와 조합 (PX_GRANULE 조정)
- Partitioning으로 처리 범위 축소
- Materialized View로 사전 집계
- Index Skip Scan 조합 활용
*/

-- PGA 사용량 시뮬레이션 비교
PROMPT
PROMPT === PGA 효율성 비교 (시뮬레이션) ===

-- 전체 범위 집계 (JPPD 없음 시뮬레이션)
SELECT 
    '전체범위 집계' AS 구분,
    COUNT(DISTINCT cust_id) AS 처리_고객수,
    COUNT(*) AS 처리_주문수,
    '높음' AS 예상_PGA_사용량
FROM T_ORDER
WHERE status = 'COMPLETE' AND order_date >= DATE '2024-01-01';

-- 특정 지역만 집계 (JPPD 적용 시뮬레이션)  
SELECT 
    '특정지역 집계' AS 구분,
    COUNT(DISTINCT o.cust_id) AS 처리_고객수,
    COUNT(*) AS 처리_주문수,
    '낮음' AS 예상_PGA_사용량
FROM T_ORDER o, T_CUSTOMER c
WHERE o.cust_id = c.cust_id 
  AND o.status = 'COMPLETE' 
  AND o.order_date >= DATE '2024-01-01'
  AND c.region = 'R01';

-- 결과 동일성 검증  
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH no_jppd AS (
    SELECT /*+ NO_PUSH_PRED */ COUNT(*) AS cnt, SUM(order_stats.총주문금액) AS sum_amt
    FROM T_CUSTOMER c,
         (SELECT cust_id, SUM(total_amount) AS 총주문금액
          FROM T_ORDER WHERE status = 'COMPLETE' AND order_date >= DATE '2024-01-01' 
          GROUP BY cust_id HAVING SUM(total_amount) > 50000) order_stats
    WHERE c.cust_id = order_stats.cust_id AND c.region = :B_REGION
), with_jppd AS (
    SELECT /*+ PUSH_PRED */ COUNT(*) AS cnt, SUM(order_stats.총주문금액) AS sum_amt  
    FROM T_CUSTOMER c,
         (SELECT o.cust_id, SUM(o.total_amount) AS 총주문금액
          FROM T_ORDER o WHERE o.status = 'COMPLETE' AND o.order_date >= DATE '2024-01-01'
          GROUP BY o.cust_id HAVING SUM(o.total_amount) > 50000) order_stats
    WHERE c.cust_id = order_stats.cust_id AND c.region = :B_REGION
)
SELECT 
    nj.cnt AS JPPD없음_건수, wj.cnt AS JPPD적용_건수,
    nj.sum_amt AS JPPD없음_금액합계, wj.sum_amt AS JPPD적용_금액합계,
    CASE WHEN nj.cnt = wj.cnt AND NVL(nj.sum_amt,0) = NVL(wj.sum_amt,0) 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM no_jppd nj, with_jppd wj;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 09 JPPD 인라인뷰 침투 실습 완료 ***  
PROMPT *** 다음: case_10.sql (WINDOW 함수 + EXISTS) ***