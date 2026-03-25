-- =============================================================================
-- Case 02: 적절한 INDEX 선택
-- 핵심 튜닝 기법: INDEX 힌트로 옵티마이저의 잘못된 INDEX 선택 수정
-- 관련 단원: INDEX ACCESS 패턴
-- 공통 데이터 세트: T_ORDER_DETAIL + T_PRODUCT 테이블 사용
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
       (SELECT COUNT(*) FROM T_ORDER_DETAIL) AS ORDER_DETAIL_건수,
       (SELECT COUNT(*) FROM T_PRODUCT) AS PRODUCT_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. INDEX 선택 시나리오 설명
PROMPT ========================================

/*
시나리오: 상품별 주문상세 조회 시 최적 INDEX 선택
테이블: T_ORDER_DETAIL (500만건), T_PRODUCT (5만건)
INDEX들:
- IDX_ORDER_DETAIL_02: (prod_id) - 상품 ID 검색용
- IDX_ORDER_DETAIL_03: (cat_id) - 카테고리 검색용  
- PK_ORDER_DETAIL: (detail_id) - 기본키

문제 상황: 옵티마이저가 잘못된 INDEX를 선택하여 성능 저하
해결책: INDEX 힌트로 최적 INDEX 강제 지정
*/

PROMPT
PROMPT ========================================
PROMPT 2. INDEX 및 데이터 분포 확인
PROMPT ========================================

-- INDEX 정보 확인
SELECT index_name, column_name, column_position
FROM user_ind_columns  
WHERE table_name = 'T_ORDER_DETAIL'
  AND index_name IN ('IDX_ORDER_DETAIL_02', 'IDX_ORDER_DETAIL_03', 'PK_ORDER_DETAIL')
ORDER BY index_name, column_position;

-- 컬럼별 선택성(Selectivity) 확인
SELECT 'prod_id' AS 컬럼명, COUNT(DISTINCT prod_id) AS DISTINCT_CNT, 
       ROUND(COUNT(DISTINCT prod_id) * 100.0 / COUNT(*), 2) AS 선택성_PCT
FROM T_ORDER_DETAIL
UNION ALL
SELECT 'cat_id', COUNT(DISTINCT cat_id), 
       ROUND(COUNT(DISTINCT cat_id) * 100.0 / COUNT(*), 2)
FROM T_ORDER_DETAIL
UNION ALL
SELECT 'detail_id', COUNT(DISTINCT detail_id),
       ROUND(COUNT(DISTINCT detail_id) * 100.0 / COUNT(*), 2)
FROM T_ORDER_DETAIL;

-- 특정 상품의 분포 확인  
SELECT prod_id, COUNT(*) AS 주문건수
FROM T_ORDER_DETAIL
WHERE prod_id BETWEEN 1000 AND 1010
GROUP BY prod_id
ORDER BY prod_id;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_PROD_ID NUMBER;
VARIABLE B_MIN_QTY NUMBER;
EXEC :B_PROD_ID := 1005;
EXEC :B_MIN_QTY := 3;

-- 튜닝 전 SQL (옵티마이저가 잘못된 INDEX 선택 가능)
-- 옵티마이저가 PK나 다른 INDEX를 선택할 수 있음
SELECT 
    od.detail_id,
    od.order_id,
    od.prod_id,
    p.prod_name,
    p.price,
    od.qty,
    od.unit_price,
    od.amount,
    p.cat_id
FROM T_ORDER_DETAIL od,
     T_PRODUCT p
WHERE od.prod_id = p.prod_id
  AND od.prod_id = :B_PROD_ID
  AND od.qty >= :B_MIN_QTY
ORDER BY od.detail_id;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (적절한 INDEX 힌트 사용)
-- prod_id 조건에 최적화된 INDEX 명시적 지정
SELECT /*+ INDEX(od IDX_ORDER_DETAIL_02) INDEX(p PK_PRODUCT) */
    od.detail_id,
    od.order_id,
    od.prod_id,
    p.prod_name,
    p.price,
    od.qty,
    od.unit_price,
    od.amount,
    p.cat_id
FROM T_ORDER_DETAIL od,
     T_PRODUCT p
WHERE od.prod_id = p.prod_id
  AND od.prod_id = :B_PROD_ID
  AND od.qty >= :B_MIN_QTY
ORDER BY od.detail_id;

PROMPT
PROMPT ========================================
PROMPT 5. INDEX 선택 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. 문제 상황:
   - 조건: prod_id = 특정값 AND qty >= 조건값
   - 옵티마이저가 통계 정보 부족으로 잘못된 INDEX 선택
   - 예: PK SCAN 후 FILTER vs prod_id INDEX 직접 ACCESS

2. INDEX 선택 기준:
   - 선택성(Selectivity): 조건에 맞는 데이터 비율
   - Clustering Factor: 물리적 데이터 배치 상태
   - INDEX Height: INDEX 깊이 (보통 2-4 레벨)
   - 조인 방법과의 연관성

3. 최적 INDEX 선택:
   - prod_id 조건 → IDX_ORDER_DETAIL_02 (prod_id)
   - 직접적인 ACCESS 조건에 맞는 INDEX 사용
   - 필터 조건 최소화

4. INDEX 힌트 사용법:
   - /*+ INDEX(테이블별칭 인덱스명) */
   - /*+ INDEX_RS(테이블별칭 인덱스명) */ : RANGE SCAN 강제
   - /*+ INDEX_FS(테이블별칭 인덱스명) */ : FULL SCAN 강제

5. 성과:
   - 불필요한 INDEX SCAN 제거
   - Consistent Gets 감소
   - 실행 시간 단축
*/

-- 다양한 INDEX 힌트별 성능 비교
PROMPT
PROMPT === INDEX 힌트별 성능 비교 ===

-- 1) INDEX 힌트 없음 (옵티마이저 선택)
SELECT COUNT(*), AVG(amount)
FROM T_ORDER_DETAIL od, T_PRODUCT p
WHERE od.prod_id = p.prod_id
  AND od.prod_id BETWEEN 1000 AND 1010
  AND od.qty >= 5;

-- 2) 적절한 INDEX 힌트
SELECT /*+ INDEX(od IDX_ORDER_DETAIL_02) */
    COUNT(*), AVG(amount)
FROM T_ORDER_DETAIL od, T_PRODUCT p
WHERE od.prod_id = p.prod_id  
  AND od.prod_id BETWEEN 1000 AND 1010
  AND od.qty >= 5;

-- 3) 부적절한 INDEX 힌트 (비교용)
SELECT /*+ INDEX(od IDX_ORDER_DETAIL_03) */
    COUNT(*), AVG(amount)
FROM T_ORDER_DETAIL od, T_PRODUCT p
WHERE od.prod_id = p.prod_id
  AND od.prod_id BETWEEN 1000 AND 1010
  AND od.qty >= 5;

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드  
PROMPT ========================================

/*
INDEX 선택 실무 가이드:

✅ INDEX 힌트 사용 권장 상황:
- 통계 정보가 부정확한 경우
- 옵티마이저 버전별 동작 차이
- 바인드 변수 peek 문제
- 특정 INDEX가 확실히 유리한 경우

❌ INDEX 힌트 사용 주의:
- 데이터 분포가 자주 변하는 경우  
- INDEX 힌트 유지보수 부담
- 과도한 힌트 사용으로 가독성 저하

🔧 INDEX 선택 체크리스트:
1. 조건절 컬럼과 INDEX 컬럼 매칭 확인
2. 선택성 높은 컬럼 우선 (DISTINCT 값 많음)
3. INDEX 컬럼 순서와 조건절 순서 매칭
4. 실행계획에서 INDEX ACCESS 방법 확인
5. Buffers/Cost 수치로 성능 검증

📊 성능 측정 지표:
- Consistent Gets (논리적 블록 읽기)
- Physical Reads (물리적 블록 읽기)  
- CPU Time, Elapsed Time
- Rows Processed vs Rows Examined 비율
*/

-- INDEX 효율성 검증 쿼리
PROMPT
PROMPT === INDEX 효율성 검증 ===

-- 조건별 데이터 분포 확인
SELECT 
    '전체 데이터' AS 구분,
    COUNT(*) AS 건수,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_ORDER_DETAIL), 2) AS 비율_PCT
FROM T_ORDER_DETAIL
UNION ALL
SELECT 
    'prod_id 1005',
    COUNT(*),
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_ORDER_DETAIL), 2)
FROM T_ORDER_DETAIL 
WHERE prod_id = 1005
UNION ALL
SELECT 
    'prod_id 1005 & qty >= 3',
    COUNT(*),
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_ORDER_DETAIL), 2)
FROM T_ORDER_DETAIL
WHERE prod_id = 1005 AND qty >= 3;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH tuning_before AS (
    SELECT COUNT(*) AS cnt, SUM(amount) AS sum_amt
    FROM T_ORDER_DETAIL od, T_PRODUCT p
    WHERE od.prod_id = p.prod_id
      AND od.prod_id = :B_PROD_ID
      AND od.qty >= :B_MIN_QTY
), tuning_after AS (
    SELECT /*+ INDEX(od IDX_ORDER_DETAIL_02) */ 
           COUNT(*) AS cnt, SUM(amount) AS sum_amt
    FROM T_ORDER_DETAIL od, T_PRODUCT p
    WHERE od.prod_id = p.prod_id
      AND od.prod_id = :B_PROD_ID
      AND od.qty >= :B_MIN_QTY
)
SELECT 
    tb.cnt AS 튜닝전_건수, ta.cnt AS 튜닝후_건수,
    tb.sum_amt AS 튜닝전_금액합계, ta.sum_amt AS 튜닝후_금액합계,
    CASE WHEN tb.cnt = ta.cnt AND tb.sum_amt = ta.sum_amt 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM tuning_before tb, tuning_after ta;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 02 적절한 INDEX 선택 실습 완료 ***
PROMPT *** 다음: case_03.sql (NL → HASH JOIN 변경) ***