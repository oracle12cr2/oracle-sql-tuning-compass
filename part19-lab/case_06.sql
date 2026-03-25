-- =============================================================================
-- Case 06: EXISTS + JOIN 순서 변경
-- 핵심 튜닝 기법: 반복 서브쿼리를 EXISTS로 변환하고 JOIN 순서 최적화
-- 관련 단원: 서브쿼리 최적화
-- 공통 데이터 세트: T_ORDER + T_CUSTOMER + T_ORDER_DETAIL 테이블 사용
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
       (SELECT COUNT(*) FROM T_ORDER_DETAIL) AS ORDER_DETAIL_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. EXISTS 최적화 시나리오 설명
PROMPT ========================================

/*
EXISTS vs IN vs JOIN 비교:
1) EXISTS: 존재 여부만 확인, 첫 번째 매치에서 즉시 중단 (효율적)
2) IN: 모든 값을 메모리에 로드 후 비교 (메모리 사용량 많음)  
3) JOIN: 실제 데이터 결합, 중복 결과 가능 (DISTINCT 필요)

시나리오: VIP 고객의 대량 주문 건들을 조회
- 조건1: 고객 등급이 VIP인 경우
- 조건2: 해당 주문에 상세가 5건 이상인 경우
- 최적화: EXISTS로 존재성 검사 + 효율적인 JOIN 순서
*/

PROMPT
PROMPT ========================================
PROMPT 2. 데이터 분포 및 선택성 분석
PROMPT ========================================

-- VIP 고객 비율 확인
SELECT grade, COUNT(*) AS 고객수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_CUSTOMER), 2) AS 비율_PCT
FROM T_CUSTOMER
GROUP BY grade
ORDER BY COUNT(*) DESC;

-- 주문별 상세 건수 분포
SELECT 
    detail_cnt_range,
    COUNT(*) AS 주문수
FROM (
    SELECT 
        CASE WHEN detail_cnt = 1 THEN '1건'
             WHEN detail_cnt BETWEEN 2 AND 5 THEN '2-5건'
             WHEN detail_cnt BETWEEN 6 AND 10 THEN '6-10건'
             ELSE '11건이상' END AS detail_cnt_range
    FROM (
        SELECT order_id, COUNT(*) AS detail_cnt
        FROM T_ORDER_DETAIL 
        WHERE order_id <= 50000  -- 샘플링
        GROUP BY order_id
    )
)
GROUP BY detail_cnt_range
ORDER BY 
    CASE detail_cnt_range 
        WHEN '1건' THEN 1 
        WHEN '2-5건' THEN 2 
        WHEN '6-10건' THEN 3 
        ELSE 4 END;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (IN + 잘못된 JOIN 순서)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_AMOUNT NUMBER;
VARIABLE B_REGION VARCHAR2(10);
EXEC :B_AMOUNT := 100000;
EXEC :B_REGION := 'R01';

-- 튜닝 전 SQL (IN 서브쿼리 + 비효율적 JOIN 순서)
-- IN 서브쿼리는 모든 값을 메모리에 로드
SELECT 
    o.order_id,
    o.cust_id,
    c.cust_name,
    c.grade,
    o.order_date,
    o.total_amount,
    o.region_code
FROM T_ORDER o,
     T_CUSTOMER c
WHERE o.cust_id = c.cust_id
  AND c.grade = 'VIP'
  AND c.region = :B_REGION
  AND o.total_amount > :B_AMOUNT
  AND o.order_id IN (
      SELECT order_id 
      FROM T_ORDER_DETAIL 
      GROUP BY order_id 
      HAVING COUNT(*) >= 5
  )
ORDER BY o.total_amount DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (EXISTS + 최적 JOIN 순서)
PROMPT ========================================

-- 튜닝 후 SQL (EXISTS + LEADING 힌트로 JOIN 순서 최적화)
SELECT /*+ LEADING(c o) USE_HASH(c o) */
    o.order_id,
    o.cust_id,
    c.cust_name,
    c.grade,
    o.order_date,
    o.total_amount,
    o.region_code
FROM T_CUSTOMER c,
     T_ORDER o
WHERE c.cust_id = o.cust_id
  AND c.grade = 'VIP'
  AND c.region = :B_REGION  
  AND o.total_amount > :B_AMOUNT
  AND EXISTS (
      SELECT 1
      FROM T_ORDER_DETAIL od
      WHERE od.order_id = o.order_id
      GROUP BY od.order_id
      HAVING COUNT(*) >= 5
  )
ORDER BY o.total_amount DESC;

PROMPT
PROMPT ========================================
PROMPT 5. EXISTS 최적화 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. EXISTS vs IN 장점:
   - EXISTS: 첫 번째 매치 시 즉시 TRUE 반환 (Short Circuit)
   - EXISTS: 메모리 사용량 적음 (값 저장 불필요)
   - EXISTS: NULL 값 처리 안전
   - IN: 모든 값을 Hash Table에 저장 후 비교

2. JOIN 순서 최적화:
   - BEFORE: T_ORDER(100만) → T_CUSTOMER(10만) 
   - AFTER: T_CUSTOMER(VIP, 5천) → T_ORDER(100만)
   - 선택성 좋은 테이블을 DRIVING TABLE로 사용

3. EXISTS 서브쿼리 최적화:
   - Correlated Subquery로 동작
   - Outer Row마다 EXISTS 조건 평가
   - GROUP BY + HAVING도 첫 번째 조건 만족 시 중단

4. 실행계획 분석:
   - FILTER operation 확인
   - Hash Join 사용 확인  
   - Cardinality 감소 확인

5. 성과:
   - 메모리 사용량 감소 (IN 절 Hash Table 제거)
   - JOIN 처리량 감소 (선택성 좋은 테이블 우선)
   - 논리적 I/O 감소
*/

-- 다양한 서브쿼리 형태 성능 비교
PROMPT
PROMPT === 서브쿼리 형태별 성능 비교 ===

-- 1) IN 서브쿼리
SELECT COUNT(*)
FROM T_ORDER o, T_CUSTOMER c
WHERE o.cust_id = c.cust_id
  AND c.grade = 'VIP'
  AND o.order_id IN (
      SELECT order_id FROM T_ORDER_DETAIL 
      GROUP BY order_id HAVING COUNT(*) >= 3
  );

-- 2) EXISTS 서브쿼리  
SELECT COUNT(*)
FROM T_ORDER o, T_CUSTOMER c
WHERE o.cust_id = c.cust_id
  AND c.grade = 'VIP'
  AND EXISTS (
      SELECT 1 FROM T_ORDER_DETAIL od
      WHERE od.order_id = o.order_id
      GROUP BY od.order_id HAVING COUNT(*) >= 3
  );

-- 3) JOIN 방식 (DISTINCT 필요)
SELECT COUNT(DISTINCT o.order_id)
FROM T_ORDER o, T_CUSTOMER c, T_ORDER_DETAIL od
WHERE o.cust_id = c.cust_id
  AND o.order_id = od.order_id
  AND c.grade = 'VIP'
HAVING COUNT(od.detail_id) >= 3;

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
EXISTS vs IN vs JOIN 선택 가이드:

✅ EXISTS 사용 권장:
- 존재 여부만 확인하는 경우
- 서브쿼리 결과가 많은 경우  
- NULL 값이 포함될 가능성
- 첫 번째 매치에서 중단 가능

✅ IN 사용 권장:
- 서브쿼리 결과가 적은 경우 (< 1000건)
- 정적인 값들과 비교
- 서브쿼리가 독립적 (Non-Correlated)

✅ JOIN 사용 권장:
- 서브쿼리 테이블의 다른 컬럼도 SELECT 필요
- 1:1 관계 보장
- 세미조인이 불가능한 복잡한 조건

🔧 JOIN 순서 최적화:
1. 선택성 높은 테이블을 DRIVING TABLE로
2. LEADING 힌트로 순서 명시
3. JOIN 방법 힌트 (USE_HASH, USE_NL) 활용
4. 실행계획에서 Cardinality 확인

📊 성능 측정 지표:
- Consistent Gets (논리적 블록 읽기)
- 실행 시간 (Elapsed Time)
- PGA 메모리 사용량
- Rows Processed vs Rows Examined
*/

-- JOIN 효율성 분석
PROMPT
PROMPT === JOIN 효율성 분석 ===

-- 각 단계별 필터링 효과 확인
SELECT '1.전체 고객' AS 단계, COUNT(*) AS 건수 FROM T_CUSTOMER
UNION ALL
SELECT '2.VIP 고객', COUNT(*) FROM T_CUSTOMER WHERE grade = 'VIP'  
UNION ALL
SELECT '3.VIP+지역 고객', COUNT(*) FROM T_CUSTOMER WHERE grade = 'VIP' AND region = 'R01'
UNION ALL
SELECT '4.해당고객 주문', COUNT(*) 
FROM T_ORDER o, T_CUSTOMER c
WHERE o.cust_id = c.cust_id AND c.grade = 'VIP' AND c.region = 'R01'
UNION ALL
SELECT '5.대량주문', COUNT(*)
FROM T_ORDER o, T_CUSTOMER c  
WHERE o.cust_id = c.cust_id AND c.grade = 'VIP' AND c.region = 'R01'
  AND o.total_amount > 100000;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH in_result AS (
    SELECT COUNT(*) AS cnt, SUM(o.total_amount) AS sum_amt
    FROM T_ORDER o, T_CUSTOMER c
    WHERE o.cust_id = c.cust_id AND c.grade = 'VIP' AND c.region = :B_REGION
      AND o.total_amount > :B_AMOUNT
      AND o.order_id IN (SELECT order_id FROM T_ORDER_DETAIL GROUP BY order_id HAVING COUNT(*) >= 5)
), exists_result AS (
    SELECT COUNT(*) AS cnt, SUM(o.total_amount) AS sum_amt
    FROM T_ORDER o, T_CUSTOMER c
    WHERE o.cust_id = c.cust_id AND c.grade = 'VIP' AND c.region = :B_REGION
      AND o.total_amount > :B_AMOUNT  
      AND EXISTS (SELECT 1 FROM T_ORDER_DETAIL od WHERE od.order_id = o.order_id 
                  GROUP BY od.order_id HAVING COUNT(*) >= 5)
)
SELECT 
    ir.cnt AS IN_건수, er.cnt AS EXISTS_건수,
    ir.sum_amt AS IN_금액합계, er.sum_amt AS EXISTS_금액합계,
    CASE WHEN ir.cnt = er.cnt AND NVL(ir.sum_amt,0) = NVL(er.sum_amt,0) 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM in_result ir, exists_result er;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 06 EXISTS + JOIN 순서 변경 실습 완료 ***
PROMPT *** 다음: case_07.sql (실행 계획 분리) ***