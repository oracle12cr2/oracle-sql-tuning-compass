-- =============================================================================
-- Case 14: JOIN 순서/방법 최적화
-- 핵심 튜닝 기법: LEADING 힌트를 통한 최적 JOIN 순서 및 방법 지정
-- 관련 단원: JOIN
-- 공통 데이터 세트: T_ORDER, T_ORDER_DETAIL, T_CATEGORY, T_PRODUCT, T_CUSTOMER
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

PROMPT
PROMPT ========================================
PROMPT 1. JOIN 순서 최적화 시나리오 설명
PROMPT ========================================

/*
시나리오: 5개 테이블 복합 JOIN에서 옵티마이저가 비효율적 JOIN 순서 선택
- T_ORDER_DETAIL (500만건) → T_ORDER (100만건) → T_PRODUCT (5만건) → T_CATEGORY (50건) → T_CUSTOMER (10만건)
- 실제로는 T_CATEGORY(50건, cat_type='PREMIUM' → ~5건)부터 시작해야 효율적

문제점: 대량 테이블부터 JOIN → 중간 결과 폭발
해결책: LEADING 힌트로 소량 필터링 테이블부터 Driving
*/

-- 데이터 분포 확인
SELECT 'T_CATEGORY (PREMIUM)' AS 구분, COUNT(*) AS 건수 FROM T_CATEGORY WHERE cat_type = 'PREMIUM'
UNION ALL SELECT 'T_CUSTOMER (VIP+SEOUL)', COUNT(*) FROM T_CUSTOMER WHERE grade = 'VIP' AND region = 'SEOUL'
UNION ALL SELECT 'T_PRODUCT', COUNT(*) FROM T_PRODUCT
UNION ALL SELECT 'T_ORDER', COUNT(*) FROM T_ORDER
UNION ALL SELECT 'T_ORDER_DETAIL', COUNT(*) FROM T_ORDER_DETAIL;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL (비효율적 JOIN 순서)
PROMPT ========================================

-- 옵티마이저가 대량 테이블부터 접근하는 경우
SELECT
    c.cat_name,
    p.prod_name,
    o.order_date,
    od.qty,
    od.amount,
    cu.cust_name,
    cu.region
FROM T_ORDER_DETAIL od,
     T_ORDER o,
     T_PRODUCT p,
     T_CATEGORY c,
     T_CUSTOMER cu
WHERE od.order_id = o.order_id
  AND od.prod_id = p.prod_id
  AND od.cat_id = c.cat_id
  AND o.cust_id = cu.cust_id
  AND c.cat_type = 'PREMIUM'
  AND cu.grade = 'VIP'
  AND cu.region = 'SEOUL'
  AND o.order_date BETWEEN '20260101' AND '20260325'
  AND o.status = 'COMPLETE'
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL (최적 JOIN 순서 지정)
PROMPT ========================================

-- LEADING: 소량 필터링 테이블부터
-- C(50→5건) → CU(VIP+SEOUL 소량) → O → OD → P
SELECT /*+
    LEADING(c cu o od p)
    USE_NL(cu o od)
    USE_HASH(p)
    INDEX(cu IDX_CUST_01)
    INDEX(o IDX_ORDER_02)
    INDEX(od IDX_DETAIL_01)
*/
    c.cat_name,
    p.prod_name,
    o.order_date,
    od.qty,
    od.amount,
    cu.cust_name,
    cu.region
FROM T_ORDER_DETAIL od,
     T_ORDER o,
     T_PRODUCT p,
     T_CATEGORY c,
     T_CUSTOMER cu
WHERE od.order_id = o.order_id
  AND od.prod_id = p.prod_id
  AND od.cat_id = c.cat_id
  AND o.cust_id = cu.cust_id
  AND c.cat_type = 'PREMIUM'
  AND cu.grade = 'VIP'
  AND cu.region = 'SEOUL'
  AND o.order_date BETWEEN '20260101' AND '20260325'
  AND o.status = 'COMPLETE'
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 4. JOIN 단계별 건수 추적
PROMPT ========================================

-- 각 단계에서 몇 건이 남는지 확인 → 최적 순서 판단 근거
SELECT '1_CATEGORY(PREMIUM)' AS 단계, COUNT(*) AS 건수
  FROM T_CATEGORY WHERE cat_type = 'PREMIUM'
UNION ALL
SELECT '2_+CUSTOMER(VIP,SEOUL)', COUNT(*)
  FROM T_CUSTOMER WHERE grade = 'VIP' AND region = 'SEOUL'
UNION ALL
SELECT '3_+ORDER(필터)', COUNT(*)
  FROM T_ORDER o, T_CUSTOMER cu
 WHERE o.cust_id = cu.cust_id
   AND cu.grade = 'VIP' AND cu.region = 'SEOUL'
   AND o.order_date BETWEEN '20260101' AND '20260325'
   AND o.status = 'COMPLETE'
UNION ALL
SELECT '4_+ORDER_DETAIL', COUNT(*)
  FROM T_ORDER o, T_CUSTOMER cu, T_ORDER_DETAIL od, T_CATEGORY c
 WHERE o.cust_id = cu.cust_id
   AND od.order_id = o.order_id
   AND od.cat_id = c.cat_id
   AND cu.grade = 'VIP' AND cu.region = 'SEOUL'
   AND o.order_date BETWEEN '20260101' AND '20260325'
   AND o.status = 'COMPLETE'
   AND c.cat_type = 'PREMIUM'
ORDER BY 단계;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 비교 및 분석
PROMPT ========================================

/*
핵심 튜닝 포인트:

1. JOIN 순서 최적화 전략:
   - 필터링 조건이 강한 테이블을 선행(Driving)으로
   - T_CATEGORY (50건 → PREMIUM 5건) 먼저
   - T_CUSTOMER (VIP+SEOUL 소량) 다음
   → 중간 결과가 작아져 후행 JOIN 부하 최소화

2. JOIN 방법 선택:
   - NL JOIN: 선행 결과 소량 + 후행 INDEX 있을 때
   - HASH JOIN: 마지막 대량 테이블 (T_PRODUCT)
   - 소량 → 소량 → 대량 순서가 이상적

3. LEADING 힌트 작성 원칙:
   - 건수 적은 테이블 → 필터링 강한 테이블 → 대량 테이블
   - JOIN 컬럼 INDEX 존재 여부 확인
   - USE_NL/USE_HASH와 함께 사용

4. 주의사항:
   - 데이터 분포 변경 시 최적 순서도 변경될 수 있음
   - 통계 정보 최신 상태 유지 필수
   - 힌트 남용 금지 — 옵티마이저 판단 먼저, 힌트는 보조
*/

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 14 JOIN 순서/방법 최적화 실습 완료 ***
