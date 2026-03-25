-- =============================================================================
-- Case 16: JOIN 순서/방법 + 서브쿼리 종합 최적화
-- 핵심 튜닝 기법: 복합 기법 — JOIN 순서, 서브쿼리, EXISTS, 스칼라 서브쿼리 조합
-- 관련 단원: JOIN + 서브쿼리
-- 공통 데이터 세트: T_ORDER, T_ORDER_DETAIL, T_CUSTOMER, T_CATEGORY, T_CODE, T_STORE
-- =============================================================================

SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

PROMPT
PROMPT ========================================
PROMPT 1. 종합 최적화 시나리오
PROMPT ========================================

/*
시나리오: 복잡한 비즈니스 쿼리
- PREMIUM 카테고리 상품을 구매한 VIP 고객의 주문 내역
- 매장별, 지역별 집계 + 코드 변환 + 서브쿼리 필터

문제점:
1. 6개 테이블 JOIN → 옵티마이저 잘못된 JOIN 순서
2. 코드 변환 JOIN 3건 → 불필요한 JOIN 부하
3. 서브쿼리 필터 비효율

해결: JOIN 순서 + 스칼라 서브쿼리 + EXISTS 복합 적용
*/

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL (비효율적)
PROMPT ========================================

-- 모든 테이블을 JOIN으로 연결, 코드 변환도 JOIN
SELECT
    o.order_id,
    o.order_date,
    cu.cust_name,
    cu.grade,
    od.amount,
    c.cat_name,
    s.store_name,
    cd1.code_name AS region_name,
    cd2.code_name AS status_name
FROM T_ORDER o,
     T_ORDER_DETAIL od,
     T_CUSTOMER cu,
     T_CATEGORY c,
     T_STORE s,
     T_CODE cd1,
     T_CODE cd2
WHERE o.order_id = od.order_id
  AND o.cust_id = cu.cust_id
  AND od.cat_id = c.cat_id
  AND o.store_id = s.store_id
  AND cd1.code_group = 'REGION' AND cd1.code = o.region_code
  AND cd2.code_group = 'STATUS' AND cd2.code = o.status
  AND c.cat_type = 'PREMIUM'
  AND cu.grade = 'VIP'
  AND o.order_date BETWEEN '20260101' AND '20260325'
  AND o.status = 'COMPLETE'
ORDER BY o.order_date DESC
FETCH FIRST 100 ROWS ONLY;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL — 종합 최적화
PROMPT ========================================

/*
최적화 전략:
1. JOIN 순서: T_CATEGORY(소량) → T_CUSTOMER(VIP 소량) → T_ORDER → T_ORDER_DETAIL
2. 코드 변환: JOIN → 스칼라 서브쿼리 (NDV 적음, 캐싱 효과)
3. 매장 변환: JOIN → 스칼라 서브쿼리
4. EXISTS 불필요 (이미 직접 JOIN)
5. FETCH FIRST → ROWNUM 최적화
*/

SELECT /*+ LEADING(c cu o od) USE_NL(cu o od) */
    o.order_id,
    o.order_date,
    cu.cust_name,
    cu.grade,
    od.amount,
    c.cat_name,
    (SELECT store_name FROM T_STORE WHERE store_id = o.store_id) AS store_name,
    (SELECT code_name FROM T_CODE WHERE code_group = 'REGION' AND code = o.region_code) AS region_name,
    (SELECT code_name FROM T_CODE WHERE code_group = 'STATUS' AND code = o.status) AS status_name
FROM T_CATEGORY c,
     T_CUSTOMER cu,
     T_ORDER o,
     T_ORDER_DETAIL od
WHERE od.order_id = o.order_id
  AND od.cat_id = c.cat_id
  AND o.cust_id = cu.cust_id
  AND c.cat_type = 'PREMIUM'
  AND cu.grade = 'VIP'
  AND o.order_date BETWEEN '20260101' AND '20260325'
  AND o.status = 'COMPLETE'
ORDER BY o.order_date DESC
FETCH FIRST 100 ROWS ONLY;

PROMPT
PROMPT ========================================
PROMPT 4. 대안 — EXISTS + 페이징 후 스칼라
PROMPT ========================================

-- VIP 고객 필터를 EXISTS로, 페이징 후 코드 변환
SELECT order_id, order_date, cust_name, grade, amount, cat_name,
       (SELECT store_name FROM T_STORE WHERE store_id = x.store_id) AS store_name,
       (SELECT code_name FROM T_CODE WHERE code_group = 'REGION' AND code = x.region_code) AS region_name,
       (SELECT code_name FROM T_CODE WHERE code_group = 'STATUS' AND code = x.status) AS status_name
FROM (
    SELECT o.order_id, o.order_date, o.store_id, o.region_code, o.status,
           cu.cust_name, cu.grade,
           od.amount,
           c.cat_name,
           ROW_NUMBER() OVER(ORDER BY o.order_date DESC) AS rn
      FROM T_ORDER o
      JOIN T_ORDER_DETAIL od ON od.order_id = o.order_id
      JOIN T_CATEGORY c ON od.cat_id = c.cat_id AND c.cat_type = 'PREMIUM'
     WHERE o.order_date BETWEEN '20260101' AND '20260325'
       AND o.status = 'COMPLETE'
       AND EXISTS (SELECT 1 FROM T_CUSTOMER cu
                    WHERE cu.cust_id = o.cust_id
                      AND cu.grade = 'VIP')
) x
JOIN T_CUSTOMER cu ON cu.cust_id = x.cust_id  -- 이름 가져오기
WHERE x.rn <= 100;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 비교 및 분석
PROMPT ========================================

/*
종합 튜닝 포인트 정리:

1. JOIN 순서 최적화:
   - 소량 테이블 Driving: T_CATEGORY(50건 중 PREMIUM ~5건)
   - 필터 강한 테이블 선행: T_CUSTOMER(VIP)
   - 7개 JOIN → 4개 JOIN + 3개 스칼라 서브쿼리

2. 코드 변환 → 스칼라 서브쿼리:
   - T_CODE, T_STORE는 NDV 적음 → 캐싱 효과 극대화
   - JOIN 제거 → 옵티마이저 부담 감소 (JOIN 순서 조합 7! → 4!)
   - 100건만 추출 후 변환 → 최대 100번만 실행

3. FETCH FIRST + ORDER BY:
   - 상위 100건만 필요 → 불필요한 전체 정렬 방지
   - INDEX 역순 스캔과 조합하면 SORT 제거 가능

4. 복합 기법 적용 순서:
   ① JOIN 개수 줄이기 (코드 변환 → 스칼라)
   ② 남은 JOIN 순서 최적화 (LEADING)
   ③ JOIN 방법 지정 (USE_NL/USE_HASH)
   ④ 페이징 최적화 (추출 후 변환)
   ⑤ EXISTS vs JOIN 선택

5. 실무 적용 가이드:
   - 먼저 EXPLAIN PLAN으로 현재 실행계획 확인
   - 각 JOIN 단계별 카디널리티(예상 건수) 확인
   - 소량 → 대량 순서로 JOIN 순서 재배치
   - 코드성 테이블은 스칼라 서브쿼리 고려
   - AUTOTRACE로 전/후 BUFFER_GETS 비교
*/

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 16 종합 최적화 실습 완료 ***
PROMPT
PROMPT ========================================
PROMPT 전체 16개 사례 실습 완료!
PROMPT cleanup.sql로 테이블 정리 가능
PROMPT ========================================
