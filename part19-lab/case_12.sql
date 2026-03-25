-- =============================================================================
-- Case 12: INDEX FULL SCAN(MIN/MAX) 유도
-- 핵심 튜닝 기법: TOP N 쿼리로 MIN/MAX 최적화 및 페이징 처리
-- 관련 단원: INDEX ACCESS 패턴
-- 공통 데이터 세트: T_ORDER 테이블 사용 (cust_id, order_date 기준)
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분, COUNT(*) AS T_ORDER_건수 FROM T_ORDER;

PROMPT
PROMPT ========================================
PROMPT 1. INDEX MIN/MAX 최적화 시나리오 설명
PROMPT ========================================

/*
INDEX MIN/MAX 최적화 개념:
- MIN/MAX 함수 사용 시 정렬 없이 INDEX의 첫/마지막 값 직접 접근
- FIRST_ROWS 힌트나 TOP N 쿼리로 INDEX FULL SCAN 유도
- 대용량 테이블에서 극소수 결과만 필요한 경우 효과적

시나리오: 고객별 최근/최초 주문일자 조회
- 각 고객의 최근 주문일자 (MAX)
- 각 고객의 최초 주문일자 (MIN)  
- INDEX (cust_id, order_date)를 활용한 효율적 접근

최적화 포인트:
- 정렬 없이 INDEX 순서로 MIN/MAX 추출
- TOP N STOPKEY로 불필요한 처리 중단
- INDEX FULL SCAN → INDEX MIN/MAX 변환
*/

PROMPT
PROMPT ========================================
PROMPT 2. INDEX 및 데이터 분포 확인
PROMPT ========================================

-- 관련 INDEX 확인
SELECT index_name, column_name, column_position
FROM user_ind_columns
WHERE table_name = 'T_ORDER'
  AND index_name = 'IDX_ORDER_02'  -- (cust_id, order_date)
ORDER BY column_position;

-- 고객별 주문 건수 분포 (TOP 10)
SELECT cust_id, COUNT(*) AS 주문건수,
       MIN(order_date) AS 최초주문일,
       MAX(order_date) AS 최근주문일
FROM T_ORDER
WHERE cust_id <= 20
GROUP BY cust_id
ORDER BY COUNT(*) DESC;

-- 날짜 범위 확인
SELECT 
    MIN(order_date) AS 전체_최초일자,
    MAX(order_date) AS 전체_최근일자,
    MAX(order_date) - MIN(order_date) AS 기간_일수
FROM T_ORDER;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (일반 MIN/MAX)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_CUST_START NUMBER;
VARIABLE B_CUST_END NUMBER;
EXEC :B_CUST_START := 1;
EXEC :B_CUST_END := 1000;

-- 튜닝 전 SQL (일반적인 GROUP BY + MIN/MAX)
-- 전체 테이블 스캔 후 그룹별 정렬하여 MIN/MAX 계산
SELECT 
    cust_id,
    COUNT(*) AS 주문건수,
    MIN(order_date) AS 최초주문일,
    MAX(order_date) AS 최근주문일,
    MAX(order_date) - MIN(order_date) AS 주문기간_일수,
    SUM(total_amount) AS 총주문금액
FROM T_ORDER
WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
  AND status = 'COMPLETE'
GROUP BY cust_id
HAVING COUNT(*) >= 2
ORDER BY MAX(order_date) DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (INDEX MIN/MAX)
PROMPT ========================================

-- 튜닝 후 SQL (INDEX 활용 MIN/MAX + FIRST_ROWS)
-- INDEX (cust_id, order_date) 순서를 활용하여 MIN/MAX 효율적 추출
SELECT /*+ FIRST_ROWS INDEX(o IDX_ORDER_02) */
    cust_id,
    COUNT(*) AS 주문건수,
    MIN(order_date) AS 최초주문일,
    MAX(order_date) AS 최근주문일,
    MAX(order_date) - MIN(order_date) AS 주문기간_일수,
    SUM(total_amount) AS 총주문금액
FROM T_ORDER o
WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
  AND status = 'COMPLETE'
GROUP BY cust_id
HAVING COUNT(*) >= 2
ORDER BY MAX(order_date) DESC;

PROMPT
PROMPT ========================================
PROMPT 5. TOP N 쿼리로 STOPKEY 활용
PROMPT ========================================

-- TOP N 쿼리 (ROWNUM을 사용한 STOPKEY)
-- 상위 N건만 처리하여 불필요한 정렬 작업 중단
SELECT * FROM (
    SELECT /*+ FIRST_ROWS INDEX(o IDX_ORDER_02) */
        cust_id,
        COUNT(*) AS 주문건수,
        MIN(order_date) AS 최초주문일,
        MAX(order_date) AS 최근주문일,
        MAX(order_date) - MIN(order_date) AS 주문기간_일수,
        SUM(total_amount) AS 총주문금액
    FROM T_ORDER o
    WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
      AND status = 'COMPLETE'
    GROUP BY cust_id
    HAVING COUNT(*) >= 2
    ORDER BY MAX(order_date) DESC
)
WHERE ROWNUM <= 10;

PROMPT
PROMPT ========================================
PROMPT 6. INDEX MIN/MAX 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. INDEX MIN/MAX 동작 원리:
   - INDEX는 정렬된 구조로 저장
   - MIN: INDEX의 첫 번째 값 직접 접근
   - MAX: INDEX의 마지막 값 직접 접근
   - 정렬 작업(SORT GROUP BY) 불필요

2. FIRST_ROWS 힌트 효과:
   - CBO에게 첫 N개 행 빠른 반환 우선 지시
   - INDEX FULL SCAN보다 INDEX MIN/MAX 선호
   - SORT 작업 최소화

3. TOP N STOPKEY:
   - ROWNUM <= N 조건으로 처리 중단
   - ORDER BY와 함께 사용 시 효과 극대화
   - 불필요한 정렬/집계 작업 방지

4. 적용 조건:
   ✅ MIN/MAX 컬럼이 INDEX에 포함
   ✅ GROUP BY 컬럼이 INDEX 선두
   ✅ 소수 그룹의 MIN/MAX 조회
   ✅ ORDER BY가 MIN/MAX 컬럼 기준

5. 성과:
   - SORT GROUP BY 작업 제거
   - INDEX SCAN 효율성 극대화  
   - 메모리 사용량 최소화
   - 응답 속도 대폭 향상
*/

-- 다양한 MIN/MAX 패턴 비교
PROMPT
PROMPT === MIN/MAX 패턴별 성능 비교 ===

-- 1) 단순 MIN/MAX (전체 테이블)
SELECT MIN(order_date) AS 전체_최초일자, MAX(order_date) AS 전체_최근일자
FROM T_ORDER
WHERE status = 'COMPLETE';

-- 2) GROUP BY MIN/MAX (INDEX 활용)
SELECT /*+ INDEX(o IDX_ORDER_02) */
    CASE WHEN cust_id <= 10 THEN 'Group1'
         WHEN cust_id <= 20 THEN 'Group2'
         ELSE 'Group3' END AS 고객그룹,
    MIN(order_date) AS 최초주문일,
    MAX(order_date) AS 최근주문일,
    COUNT(*) AS 주문건수
FROM T_ORDER o
WHERE cust_id BETWEEN 1 AND 30
  AND status = 'COMPLETE'
GROUP BY CASE WHEN cust_id <= 10 THEN 'Group1'
              WHEN cust_id <= 20 THEN 'Group2'
              ELSE 'Group3' END;

-- 3) 고객별 최근 주문 TOP 1 (INDEX SCAN + STOPKEY)
SELECT /*+ INDEX(o IDX_ORDER_02) */
    cust_id, order_date, order_id, total_amount
FROM (
    SELECT cust_id, order_date, order_id, total_amount,
           ROW_NUMBER() OVER (PARTITION BY cust_id ORDER BY order_date DESC) AS rn
    FROM T_ORDER o
    WHERE cust_id BETWEEN 1 AND 10
      AND status = 'COMPLETE'
)
WHERE rn = 1
ORDER BY cust_id;

PROMPT
PROMPT ========================================
PROMPT 7. 실무 적용 가이드
PROMPT ========================================

/*
INDEX MIN/MAX 실무 최적화 가이드:

✅ INDEX MIN/MAX 적용 권장:
- GROUP BY + MIN/MAX 조합
- MIN/MAX 컬럼이 INDEX에 포함  
- 결과 건수가 적은 경우 (< 1000건)
- 정렬된 INDEX 순서 활용 가능

❌ INDEX MIN/MAX 적용 주의:
- 복잡한 WHERE 조건으로 INDEX 비효율
- 대량 그룹의 MIN/MAX (>10만 그룹)
- MIN/MAX 이외 복잡한 집계함수 포함

🔧 최적화 기법:
1. INDEX 컬럼 순서 최적화 (GROUP BY → MIN/MAX)
2. FIRST_ROWS 힌트 적극 활용
3. TOP N 쿼리로 STOPKEY 유도
4. 불필요한 컬럼 SELECT 제거

📊 성능 측정 지표:
- SORT GROUP BY 작업 유무
- INDEX FULL SCAN vs INDEX MIN/MAX
- 메모리 사용량 (PGA)
- 응답 시간 개선도

💡 고급 활용 패턴:
- KEEP DENSE_RANK 함수 활용
- 분석함수 FIRST_VALUE/LAST_VALUE
- INDEX SKIP SCAN과 조합
- Partitioning INDEX 활용
*/

-- INDEX MIN/MAX vs 일반 GROUP BY 성능 비교
PROMPT
PROMPT === INDEX MIN/MAX 효과 검증 ===

-- 처리 방식별 실행계획 비교를 위한 동일 결과 쿼리
WITH index_minmax AS (
    SELECT /*+ FIRST_ROWS INDEX(o IDX_ORDER_02) */
        COUNT(DISTINCT cust_id) AS 고객수,
        MIN(order_date) AS 전체_최초일,
        MAX(order_date) AS 전체_최근일
    FROM T_ORDER o
    WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
      AND status = 'COMPLETE'
), normal_groupby AS (
    SELECT 
        COUNT(DISTINCT cust_id) AS 고객수,
        MIN(order_date) AS 전체_최초일,
        MAX(order_date) AS 전체_최근일
    FROM T_ORDER
    WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
      AND status = 'COMPLETE'
)
SELECT 
    im.고객수 AS INDEX방식_고객수, ng.고객수 AS 일반방식_고객수,
    im.전체_최초일 AS INDEX방식_최초일, ng.전체_최초일 AS 일반방식_최초일,
    im.전체_최근일 AS INDEX방식_최근일, ng.전체_최근일 AS 일반방식_최근일,
    CASE WHEN im.고객수 = ng.고객수 AND im.전체_최초일 = ng.전체_최초일 
              AND im.전체_최근일 = ng.전체_최근일 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM index_minmax im, normal_groupby ng;

-- TOP N STOPKEY 효과 확인
PROMPT
PROMPT === TOP N STOPKEY 효과 확인 ===

SELECT '전체처리' AS 구분, COUNT(*) AS 예상_처리건수
FROM T_ORDER
WHERE cust_id BETWEEN :B_CUST_START AND :B_CUST_END
  AND status = 'COMPLETE'

UNION ALL

SELECT 'TOP 10만', 10 AS 예상_처리건수
FROM DUAL;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 12 INDEX MIN/MAX 최적화 실습 완료 ***
PROMPT *** 다음: case_13.sql (페이징 후 JOIN + 스칼라) ***