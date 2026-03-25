-- =============================================================================
-- Case 15: JPPD로 인라인뷰 GROUP BY 제거
-- 핵심 튜닝 기법: PUSH_PRED로 인라인뷰 안으로 조건 침투 → 전체 GROUP BY 제거
-- 관련 단원: JOIN (JPPD)
-- 공통 데이터 세트: T_CUSTOMER, T_ORDER
-- =============================================================================

SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

PROMPT
PROMPT ========================================
PROMPT 1. JPPD GROUP BY 제거 시나리오
PROMPT ========================================

/*
시나리오: VIP+SEOUL 고객(소량)의 주문 통계를 조회
- 인라인뷰가 T_ORDER 전체(100만건)를 GROUP BY
- 실제 필요한 건 VIP+SEOUL 고객 몇십 명분만

문제점: 100만건 전체 GROUP BY → PGA 대량 사용 + 시간 소요
해결책: JPPD로 cust_id 조건을 인라인뷰 안으로 밀어넣기
        → 해당 cust_id만 INDEX로 집계
*/

-- 대상 고객 수 확인
SELECT COUNT(*) AS "VIP+SEOUL 고객수" FROM T_CUSTOMER WHERE grade = 'VIP' AND region = 'SEOUL';
SELECT COUNT(*) AS "전체 주문수" FROM T_ORDER;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL (전체 GROUP BY)
PROMPT ========================================

-- 인라인뷰가 T_ORDER 전체를 GROUP BY한 후 JOIN
SELECT a.cust_id, a.cust_name, a.grade,
       b.order_cnt, b.total_amt, b.avg_amt, b.last_order
  FROM T_CUSTOMER a,
       (SELECT cust_id,
               COUNT(*) AS order_cnt,
               SUM(total_amount) AS total_amt,
               ROUND(AVG(total_amount), 2) AS avg_amt,
               MAX(order_date) AS last_order
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.grade = 'VIP'
   AND a.region = 'SEOUL'
 ORDER BY b.total_amt DESC;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL — 방법 1: JPPD (NO_MERGE + PUSH_PRED)
PROMPT ========================================

-- PUSH_PRED: a.cust_id 조건이 인라인뷰 안으로 침투
-- → T_ORDER에서 해당 cust_id만 INDEX RANGE SCAN 후 집계
SELECT a.cust_id, a.cust_name, a.grade,
       b.order_cnt, b.total_amt, b.avg_amt, b.last_order
  FROM T_CUSTOMER a,
       (SELECT /*+ NO_MERGE PUSH_PRED */
               cust_id,
               COUNT(*) AS order_cnt,
               SUM(total_amount) AS total_amt,
               ROUND(AVG(total_amount), 2) AS avg_amt,
               MAX(order_date) AS last_order
          FROM T_ORDER
         GROUP BY cust_id) b
 WHERE a.cust_id = b.cust_id
   AND a.grade = 'VIP'
   AND a.region = 'SEOUL'
 ORDER BY b.total_amt DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL — 방법 2: 스칼라 서브쿼리 (대안)
PROMPT ========================================

-- JPPD가 안 먹힐 때의 대안
-- 각 컬럼을 스칼라 서브쿼리로 분리 (캐싱 활용)
SELECT a.cust_id, a.cust_name, a.grade,
       (SELECT COUNT(*) FROM T_ORDER o WHERE o.cust_id = a.cust_id) AS order_cnt,
       (SELECT SUM(total_amount) FROM T_ORDER o WHERE o.cust_id = a.cust_id) AS total_amt,
       (SELECT ROUND(AVG(total_amount), 2) FROM T_ORDER o WHERE o.cust_id = a.cust_id) AS avg_amt,
       (SELECT MAX(order_date) FROM T_ORDER o WHERE o.cust_id = a.cust_id) AS last_order
  FROM T_CUSTOMER a
 WHERE a.grade = 'VIP'
   AND a.region = 'SEOUL'
 ORDER BY total_amt DESC;

PROMPT
PROMPT ========================================
PROMPT 5. 튜닝 후 SQL — 방법 3: 명시적 JOIN 변환
PROMPT ========================================

-- 인라인뷰 제거, 직접 JOIN + GROUP BY
SELECT a.cust_id, a.cust_name, a.grade,
       COUNT(o.order_id) AS order_cnt,
       SUM(o.total_amount) AS total_amt,
       ROUND(AVG(o.total_amount), 2) AS avg_amt,
       MAX(o.order_date) AS last_order
  FROM T_CUSTOMER a
  JOIN T_ORDER o ON a.cust_id = o.cust_id
 WHERE a.grade = 'VIP'
   AND a.region = 'SEOUL'
 GROUP BY a.cust_id, a.cust_name, a.grade
 ORDER BY total_amt DESC;

PROMPT
PROMPT ========================================
PROMPT 6. 성능 비교 및 분석
PROMPT ========================================

/*
핵심 튜닝 포인트:

1. JPPD (Join Predicate Push Down):
   - 메인 쿼리의 JOIN 조건을 인라인뷰 안으로 침투
   - GROUP BY가 있는 인라인뷰는 뷰 머징 불가 → JPPD로 해결
   - NO_MERGE: 뷰 머징 방지
   - PUSH_PRED: JOIN 조건을 인라인뷰 안으로 푸시

2. 성능 차이:
   튜닝 전: T_ORDER 100만건 전체 GROUP BY → PGA 대량 사용
   튜닝 후: VIP+SEOUL 고객(~50명)분만 INDEX 조회 → I/O 최소화

3. JPPD 적용 조건:
   - 인라인뷰에 GROUP BY, DISTINCT, ROWNUM 등으로 뷰 머징 불가
   - 후행 테이블에 JOIN 컬럼 인덱스 존재 (T_ORDER.cust_id)
   - 선행 결과가 소량일 때 효과 극대화

4. 주의사항:
   - 선행 결과가 대량이면 오히려 느려질 수 있음 (건건이 INDEX 접근)
   - 실행계획에서 VIEW PUSHED PREDICATE 확인
   - _push_join_predicate 파라미터 = TRUE 확인

5. 대안 기법 비교:
   - JPPD: 가장 깔끔, 옵티마이저 지원 필요
   - 스칼라 서브쿼리: 컬럼 4개 = 4번 반복 ACCESS (비효율)
   - 명시적 JOIN: GROUP BY 변환, 항상 가능하지는 않음
*/

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 15 JPPD GROUP BY 제거 실습 완료 ***
