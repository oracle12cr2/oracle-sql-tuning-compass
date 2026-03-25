-- =============================================================================
-- Case 08: JOIN 순서 변경 + 스칼라 서브쿼리
-- 핵심 튜닝 기법: JOIN 순서 최적화 및 스칼라 서브쿼리 캐싱 활용
-- 관련 단원: JOIN 최적화 + 서브쿼리 최적화  
-- 공통 데이터 세트: T_ORDER + T_CUSTOMER + T_CODE 테이블 사용
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
       (SELECT COUNT(*) FROM T_CUSTOMER) AS CUSTOMER_건수,
       (SELECT COUNT(*) FROM T_CODE) AS CODE_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. 복합 최적화 시나리오 설명
PROMPT ========================================

/*
복합 최적화 기법 조합:
1) JOIN 순서 최적화: 선택성 높은 테이블을 먼저 처리
2) 스칼라 서브쿼리: 코드성 테이블 조인을 캐싱으로 대체

시나리오: 특정 지역 VIP 고객의 주문 현황 + 상태코드명 조회
- T_CUSTOMER (10만) → 지역+등급 필터 → 매우 소수
- T_ORDER (100만) → 고객별 주문들
- T_CODE (200) → 상태코드명 (스칼라 서브쿼리로 캐싱)

최적화 포인트:
- 소수 VIP 고객 → 해당 고객 주문들 JOIN (NL JOIN 유리)
- 상태코드는 중복이 많아 스칼라 서브쿼리 캐싱 효과 높음
*/

PROMPT
PROMPT ========================================
PROMPT 2. JOIN 순서 분석 및 데이터 분포
PROMPT ========================================

-- 각 테이블별 필터링 효과 분석
SELECT '전체 고객' AS 구분, COUNT(*) AS 건수 FROM T_CUSTOMER
UNION ALL
SELECT 'VIP 고객', COUNT(*) FROM T_CUSTOMER WHERE grade = 'VIP'
UNION ALL  
SELECT 'VIP + R01 지역', COUNT(*) FROM T_CUSTOMER WHERE grade = 'VIP' AND region = 'R01'
UNION ALL
SELECT '전체 주문', COUNT(*) FROM T_ORDER
UNION ALL
SELECT '해당고객 주문', COUNT(*) 
FROM T_ORDER o, T_CUSTOMER c 
WHERE o.cust_id = c.cust_id AND c.grade = 'VIP' AND c.region = 'R01'
ORDER BY 
    CASE 구분 
        WHEN '전체 고객' THEN 1 WHEN 'VIP 고객' THEN 2 WHEN 'VIP + R01 지역' THEN 3
        WHEN '전체 주문' THEN 4 WHEN '해당고객 주문' THEN 5 END;

-- 상태코드 분포 (스칼라 서브쿼리 캐싱 효과 분석)
SELECT status, COUNT(*) AS 주문건수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_ORDER), 2) AS 비율_PCT
FROM T_ORDER
GROUP BY status
ORDER BY COUNT(*) DESC;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (잘못된 JOIN 순서)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_REGION VARCHAR2(10);
VARIABLE B_GRADE VARCHAR2(10);
VARIABLE B_AMOUNT NUMBER;
EXEC :B_REGION := 'R01';
EXEC :B_GRADE := 'VIP';  
EXEC :B_AMOUNT := 50000;

-- 튜닝 전 SQL (큰 테이블부터 JOIN + 일반 JOIN으로 코드 조회)
-- T_ORDER(100만) → T_CUSTOMER(10만) → T_CODE(200) 순서로 JOIN
SELECT 
    o.order_id,
    o.cust_id,
    c.cust_name,
    c.grade,
    c.region,
    o.order_date,
    o.status,
    cd.code_name AS 상태명,
    o.total_amount
FROM T_ORDER o,
     T_CUSTOMER c,
     T_CODE cd
WHERE o.cust_id = c.cust_id
  AND o.status = cd.code
  AND cd.code_group = 'ORDER_STATUS'
  AND c.region = :B_REGION
  AND c.grade = :B_GRADE
  AND o.total_amount > :B_AMOUNT
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (최적 JOIN + 스칼라 서브쿼리)
PROMPT ========================================

-- 튜닝 후 SQL (최적 JOIN 순서 + 스칼라 서브쿼리)
-- 선택성 높은 고객 테이블 → 주문 테이블 + 코드는 스칼라 서브쿼리
SELECT /*+ LEADING(c o) USE_NL(c o) */
    o.order_id,
    o.cust_id,
    c.cust_name,
    c.grade,
    c.region,
    o.order_date,
    o.status,
    (SELECT code_name 
     FROM T_CODE 
     WHERE code = o.status AND code_group = 'ORDER_STATUS') AS 상태명,
    o.total_amount
FROM T_CUSTOMER c,
     T_ORDER o  
WHERE c.cust_id = o.cust_id
  AND c.region = :B_REGION
  AND c.grade = :B_GRADE
  AND o.total_amount > :B_AMOUNT
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 5. 복합 최적화 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. JOIN 순서 최적화:
   BEFORE: T_ORDER(100만) → T_CUSTOMER(필터 후 수백건)
   AFTER: T_CUSTOMER(필터 후 수백건) → T_ORDER(100만)
   
   효과: NL JOIN 시 Outer 테이블 크기가 성능 결정
        작은 테이블 → 큰 테이블 순서로 INDEX Lookup 최소화

2. 스칼라 서브쿼리 활용:
   - T_CODE JOIN 제거 → 스칼라 서브쿼리로 대체
   - 상태코드 4-5종류만 존재 → 높은 캐시 HIT 비율
   - 동일 status 값에 대해 캐싱된 code_name 재사용

3. NL JOIN vs HASH JOIN 선택:
   - Outer 테이블이 매우 작음 (수백건) → NL JOIN 유리  
   - Inner 테이블 INDEX 활용 가능
   - Random ACCESS 최소화

4. 실행계획 분석 포인트:
   - LEADING 힌트로 JOIN 순서 확인
   - NL JOIN operation 확인
   - FILTER operation (스칼라 서브쿼리) 확인
   - A-Rows 감소 확인

5. 성과:
   - Consistent Gets 대폭 감소
   - JOIN Operation 최소화  
   - 코드 테이블 ACCESS 횟수 감소 (캐싱 효과)
*/

-- 복합 최적화 효과 비교
PROMPT
PROMPT === JOIN 방법별 성능 비교 ===

-- 1) HASH JOIN 강제 (큰 데이터용)
SELECT /*+ USE_HASH(c o) LEADING(c o) */ COUNT(*), SUM(o.total_amount)
FROM T_CUSTOMER c, T_ORDER o
WHERE c.cust_id = o.cust_id
  AND c.region = :B_REGION  
  AND c.grade = :B_GRADE
  AND o.total_amount > :B_AMOUNT;

-- 2) NL JOIN 강제 (소량 데이터용)  
SELECT /*+ USE_NL(c o) LEADING(c o) */ COUNT(*), SUM(o.total_amount)
FROM T_CUSTOMER c, T_ORDER o
WHERE c.cust_id = o.cust_id
  AND c.region = :B_REGION
  AND c.grade = :B_GRADE  
  AND o.total_amount > :B_AMOUNT;

PROMPT
PROMPT === 스칼라 vs JOIN 비교 ===

-- 1) 일반 JOIN
SELECT COUNT(DISTINCT o.order_id), COUNT(*) AS total_access
FROM T_ORDER o, T_CUSTOMER c, T_CODE cd
WHERE o.cust_id = c.cust_id AND o.status = cd.code
  AND cd.code_group = 'ORDER_STATUS'
  AND c.region = 'R01' AND c.grade = 'VIP';

-- 2) 스칼라 서브쿼리 (ACCESS 횟수 비교 어려움, 결과 건수로 확인)
SELECT COUNT(*) 
FROM T_ORDER o, T_CUSTOMER c
WHERE o.cust_id = c.cust_id  
  AND c.region = 'R01' AND c.grade = 'VIP'
  AND (SELECT 1 FROM T_CODE WHERE code = o.status AND code_group = 'ORDER_STATUS') = 1;

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
복합 최적화 실무 가이드:

🔹 JOIN 순서 최적화 원칙:
1. 필터링 효과가 높은 테이블을 DRIVING TABLE로
2. 1:M 관계에서 1쪽을 먼저 (작은 쪽 → 큰 쪽)  
3. LEADING 힌트로 명시적 제어
4. NL vs HASH JOIN 적절히 선택

🔹 스칼라 서브쿼리 적용 기준:
✅ 참조 테이블이 작음 (< 1000건)
✅ JOIN 키 DISTINCT 값 적음 (< 100개)  
✅ 1:1 관계 보장
✅ 참조 테이블 변경 빈도 낮음

🔹 NL JOIN 적용 조건:
✅ Outer 테이블이 작음 (< 10만건)
✅ Inner 테이블에 효율적 INDEX 존재
✅ OLTP 환경 (소량 데이터 처리)

🔹 HASH JOIN 적용 조건:
✅ 조인 결과가 큼 (전체의 5% 이상)
✅ 양쪽 테이블 모두 범위 조건
✅ 배치/DW 환경 (대량 데이터 처리)

🔧 튜닝 체크리스트:
1. 각 테이블별 필터링 Cardinality 확인
2. JOIN 키 INDEX 존재 여부 확인  
3. 실행계획에서 JOIN 순서/방법 확인
4. 스칼라 서브쿼리 캐싱 효과 측정
5. Consistent Gets, 실행시간 비교
*/

-- 단계별 필터링 효과 상세 분석
PROMPT
PROMPT === 단계별 필터링 효과 분석 ===

WITH step_analysis AS (
    SELECT 
        (SELECT COUNT(*) FROM T_CUSTOMER) AS step1_all_customers,
        (SELECT COUNT(*) FROM T_CUSTOMER WHERE grade = :B_GRADE) AS step2_vip_customers,  
        (SELECT COUNT(*) FROM T_CUSTOMER WHERE grade = :B_GRADE AND region = :B_REGION) AS step3_filtered_customers,
        (SELECT COUNT(*) FROM T_ORDER) AS step4_all_orders,
        (SELECT COUNT(*) FROM T_ORDER o, T_CUSTOMER c 
         WHERE o.cust_id = c.cust_id AND c.grade = :B_GRADE AND c.region = :B_REGION) AS step5_customer_orders,
        (SELECT COUNT(*) FROM T_ORDER o, T_CUSTOMER c 
         WHERE o.cust_id = c.cust_id AND c.grade = :B_GRADE AND c.region = :B_REGION 
         AND o.total_amount > :B_AMOUNT) AS step6_final_result
    FROM DUAL
)
SELECT 
    '1.전체 고객' AS 단계, step1_all_customers AS 건수, 
    100.0 AS 남은비율_PCT FROM step_analysis
UNION ALL
SELECT '2.VIP 고객', step2_vip_customers, 
       ROUND(step2_vip_customers * 100.0 / step1_all_customers, 2) FROM step_analysis  
UNION ALL
SELECT '3.VIP+지역 고객', step3_filtered_customers,
       ROUND(step3_filtered_customers * 100.0 / step1_all_customers, 2) FROM step_analysis
UNION ALL  
SELECT '4.전체 주문', step4_all_orders, 
       ROUND(step4_all_orders * 100.0 / step4_all_orders, 2) FROM step_analysis
UNION ALL
SELECT '5.해당고객 주문', step5_customer_orders,
       ROUND(step5_customer_orders * 100.0 / step4_all_orders, 2) FROM step_analysis
UNION ALL
SELECT '6.최종 결과', step6_final_result,  
       ROUND(step6_final_result * 100.0 / step4_all_orders, 2) FROM step_analysis;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH before_tuning AS (
    SELECT COUNT(*) AS cnt, SUM(o.total_amount) AS sum_amt
    FROM T_ORDER o, T_CUSTOMER c, T_CODE cd
    WHERE o.cust_id = c.cust_id AND o.status = cd.code AND cd.code_group = 'ORDER_STATUS'
      AND c.region = :B_REGION AND c.grade = :B_GRADE AND o.total_amount > :B_AMOUNT
), after_tuning AS (
    SELECT COUNT(*) AS cnt, SUM(o.total_amount) AS sum_amt
    FROM T_CUSTOMER c, T_ORDER o
    WHERE c.cust_id = o.cust_id AND c.region = :B_REGION AND c.grade = :B_GRADE 
      AND o.total_amount > :B_AMOUNT
      AND (SELECT 1 FROM T_CODE WHERE code = o.status AND code_group = 'ORDER_STATUS') = 1
)
SELECT 
    bt.cnt AS 튜닝전_건수, at.cnt AS 튜닝후_건수,
    bt.sum_amt AS 튜닝전_금액합계, at.sum_amt AS 튜닝후_금액합계,
    CASE WHEN bt.cnt = at.cnt AND NVL(bt.sum_amt,0) = NVL(at.sum_amt,0) 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM before_tuning bt, after_tuning at;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 08 JOIN 순서 + 스칼라 서브쿼리 복합 최적화 실습 완료 ***
PROMPT *** 다음: case_09.sql (JPPD + NL JOIN) ***