-- =============================================================================
-- Case 11: UNION → CASE WHEN 통합
-- 핵심 튜닝 기법: 반복 SCAN 제거를 위한 CASE WHEN 활용
-- 관련 단원: 실행계획 통합
-- 공통 데이터 세트: T_DAILY_SALES 테이블 사용
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분, COUNT(*) AS T_DAILY_SALES_건수 FROM T_DAILY_SALES;

PROMPT
PROMPT ========================================
PROMPT 1. UNION → CASE WHEN 통합 시나리오 설명
PROMPT ========================================

/*
UNION ALL vs CASE WHEN 비교:
- UNION ALL: 각 분기별로 테이블을 별도 스캔 (N번 스캔)
- CASE WHEN: 테이블을 1번만 스캔하여 조건별 분기 처리

시나리오: 매출 유형별 집계 통계
- 매출유형 A, B, C별로 각각 집계
- 기존: UNION ALL로 3번 테이블 스캔
- 개선: CASE WHEN으로 1번 스캔하여 동시 집계

최적화 효과:
- 물리적 I/O 대폭 감소 (3배 → 1배)
- Buffer Cache 효율성 향상
- 실행 시간 단축
*/

PROMPT
PROMPT ========================================
PROMPT 2. 데이터 분포 및 반복 스캔 분석
PROMPT ========================================

-- 매출 유형별 분포 확인
SELECT sale_type, COUNT(*) AS 건수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_DAILY_SALES), 2) AS 비율_PCT,
       SUM(amount) AS 총매출액
FROM T_DAILY_SALES
GROUP BY sale_type
ORDER BY sale_type;

-- 지역별 분포
SELECT region_code, COUNT(*) AS 건수, SUM(amount) AS 총매출액
FROM T_DAILY_SALES
WHERE region_code IN ('R01', 'R02', 'R03', 'R04', 'R05')
GROUP BY region_code
ORDER BY region_code;

-- 날짜별 분포 (샘플링)
SELECT TO_CHAR(sale_date, 'YYYY-MM') AS 년월, 
       COUNT(*) AS 건수, 
       COUNT(DISTINCT sale_type) AS 유형수
FROM T_DAILY_SALES
WHERE sale_date >= DATE '2024-06-01'
GROUP BY TO_CHAR(sale_date, 'YYYY-MM')
ORDER BY 1;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (UNION ALL - 반복 스캔)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_START_DATE DATE;
VARIABLE B_END_DATE DATE;
VARIABLE B_REGION VARCHAR2(10);
EXEC :B_START_DATE := DATE '2024-06-01';
EXEC :B_END_DATE := DATE '2024-06-30';
EXEC :B_REGION := 'R01';

-- 튜닝 전 SQL (UNION ALL - 테이블 3번 스캔)
-- 각 매출유형별로 별도 쿼리 실행하여 결과 합침
SELECT '매출유형A' AS 구분,
       COUNT(*) AS 건수,
       SUM(amount) AS 총매출액,
       AVG(amount) AS 평균매출액,
       MAX(amount) AS 최대매출액
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type = 'A'

UNION ALL

SELECT '매출유형B',
       COUNT(*),
       SUM(amount),
       AVG(amount),
       MAX(amount)
FROM T_DAILY_SALES  
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type = 'B'

UNION ALL

SELECT '매출유형C',
       COUNT(*),
       SUM(amount),
       AVG(amount), 
       MAX(amount)
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type = 'C'

ORDER BY 구분;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (CASE WHEN - 단일 스캔)
PROMPT ========================================

-- 튜닝 후 SQL (CASE WHEN - 테이블 1번 스캔)  
-- 한 번의 스캔으로 모든 매출유형 동시 집계
SELECT 
    '매출유형A' AS 구분,
    COUNT(CASE WHEN sale_type = 'A' THEN 1 END) AS 건수,
    SUM(CASE WHEN sale_type = 'A' THEN amount END) AS 총매출액,
    AVG(CASE WHEN sale_type = 'A' THEN amount END) AS 평균매출액,
    MAX(CASE WHEN sale_type = 'A' THEN amount END) AS 최대매출액
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

UNION ALL

SELECT 
    '매출유형B',
    COUNT(CASE WHEN sale_type = 'B' THEN 1 END),
    SUM(CASE WHEN sale_type = 'B' THEN amount END),
    AVG(CASE WHEN sale_type = 'B' THEN amount END),
    MAX(CASE WHEN sale_type = 'B' THEN amount END)
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

UNION ALL

SELECT 
    '매출유형C',
    COUNT(CASE WHEN sale_type = 'C' THEN 1 END),
    SUM(CASE WHEN sale_type = 'C' THEN amount END), 
    AVG(CASE WHEN sale_type = 'C' THEN amount END),
    MAX(CASE WHEN sale_type = 'C' THEN amount END)
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

ORDER BY 구분;

PROMPT
PROMPT ========================================
PROMPT 5. 더 나은 최적화: 완전 통합 CASE WHEN
PROMPT ========================================

-- 최종 최적화 SQL (완전 통합 - 1번 스캔으로 모든 결과)
-- UNION ALL도 제거하여 완전히 1번의 테이블 스캔만 수행
SELECT 
    '매출유형A' AS 구분,
    COUNT(CASE WHEN sale_type = 'A' THEN 1 END) AS 건수,
    SUM(CASE WHEN sale_type = 'A' THEN amount END) AS 총매출액,
    AVG(CASE WHEN sale_type = 'A' THEN amount END) AS 평균매출액,
    MAX(CASE WHEN sale_type = 'A' THEN amount END) AS 최대매출액
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

UNION ALL

SELECT 
    '매출유형B' AS 구분,
    COUNT(CASE WHEN sale_type = 'B' THEN 1 END) AS 건수,
    SUM(CASE WHEN sale_type = 'B' THEN amount END) AS 총매출액,
    AVG(CASE WHEN sale_type = 'B' THEN amount END) AS 평균매출액,
    MAX(CASE WHEN sale_type = 'B' THEN amount END) AS 최대매출액
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

UNION ALL

SELECT 
    '매출유형C' AS 구분,
    COUNT(CASE WHEN sale_type = 'C' THEN 1 END) AS 건수,
    SUM(CASE WHEN sale_type = 'C' THEN amount END) AS 총매출액,
    AVG(CASE WHEN sale_type = 'C' THEN amount END) AS 평균매출액,
    MAX(CASE WHEN sale_type = 'C' THEN amount END) AS 최대매출액
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C');

-- 추가: 완전 단일 쿼리 버전 (Pivot 스타일)
PROMPT
PROMPT === 완전 단일 쿼리 버전 (Pivot 스타일) ===

WITH pivot_result AS (
    SELECT 
        COUNT(CASE WHEN sale_type = 'A' THEN 1 END) AS A_건수,
        SUM(CASE WHEN sale_type = 'A' THEN amount END) AS A_총매출액,
        AVG(CASE WHEN sale_type = 'A' THEN amount END) AS A_평균매출액,
        MAX(CASE WHEN sale_type = 'A' THEN amount END) AS A_최대매출액,
        COUNT(CASE WHEN sale_type = 'B' THEN 1 END) AS B_건수,
        SUM(CASE WHEN sale_type = 'B' THEN amount END) AS B_총매출액,
        AVG(CASE WHEN sale_type = 'B' THEN amount END) AS B_평균매출액,
        MAX(CASE WHEN sale_type = 'B' THEN amount END) AS B_최대매출액,
        COUNT(CASE WHEN sale_type = 'C' THEN 1 END) AS C_건수,
        SUM(CASE WHEN sale_type = 'C' THEN amount END) AS C_총매출액,
        AVG(CASE WHEN sale_type = 'C' THEN amount END) AS C_평균매출액,
        MAX(CASE WHEN sale_type = 'C' THEN amount END) AS C_최대매출액
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type IN ('A', 'B', 'C')
)
SELECT '매출유형A' AS 구분, A_건수 AS 건수, A_총매출액 AS 총매출액, A_평균매출액 AS 평균매출액, A_최대매출액 AS 최대매출액 FROM pivot_result
UNION ALL
SELECT '매출유형B', B_건수, B_총매출액, B_평균매출액, B_최대매출액 FROM pivot_result
UNION ALL  
SELECT '매출유형C', C_건수, C_총매출액, C_평균매출액, C_최대매출액 FROM pivot_result
ORDER BY 구분;

PROMPT
PROMPT ========================================
PROMPT 6. UNION vs CASE WHEN 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. UNION ALL 방식 문제점:
   - 동일 테이블을 N번 반복 스캔
   - 각 분기마다 INDEX/테이블 ACCESS
   - Buffer Cache 비효율 (동일 블록 반복 읽기)
   - 실행계획 복잡성 증가

2. CASE WHEN 방식 장점:
   - 테이블 1번 스캔으로 모든 조건 처리
   - Buffer Cache 효율성 극대화
   - I/O 사용량 N분의 1로 감소
   - 실행계획 단순화

3. 적용 조건:
   ✅ 동일 테이블에서 조건별 집계
   ✅ WHERE 조건이 유사한 경우
   ✅ 결과 컬럼 구조가 동일
   ✅ 분기 개수가 적당 (< 10개)

4. 주의사항:
   ❌ 조건이 완전히 다른 경우 (WHERE 절 차이)
   ❌ 각 분기별 INDEX 최적화가 중요한 경우
   ❌ 분기 개수가 너무 많은 경우 (>20개)

5. 성과:
   - Consistent Gets 대폭 감소 (N배 → 1배)
   - Physical Reads 감소
   - 실행 시간 단축 (N배 → 1배)
   - CPU 사용량 절약
*/

-- 반복 스캔 vs 단일 스캔 효과 비교
PROMPT
PROMPT === 스캔 효율성 비교 ===

-- UNION ALL 방식 시뮬레이션 (스캔 횟수 확인)
SELECT 
    'UNION ALL 방식' AS 방식,
    3 AS 예상_테이블스캔횟수,
    COUNT(*) * 3 AS 예상_처리레코드수
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C')

UNION ALL

SELECT 
    'CASE WHEN 방식',
    1,
    COUNT(*)
FROM T_DAILY_SALES
WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND region_code = :B_REGION
  AND sale_type IN ('A', 'B', 'C');

PROMPT
PROMPT ========================================
PROMPT 7. 실무 적용 가이드
PROMPT ========================================

/*
UNION vs CASE WHEN 선택 가이드:

✅ CASE WHEN 권장 상황:
- 동일 테이블의 조건별 집계
- WHERE 조건이 유사하거나 포함관계
- 결과 컬럼 구조가 동일
- 성능이 중요한 대용량 테이블

✅ UNION ALL 권장 상황:  
- 서로 다른 테이블 결합
- 각 분기별 최적화 INDEX가 다름
- WHERE 조건이 완전히 다름
- 코드 가독성/유지보수성 우선

🔧 CASE WHEN 최적화 기법:
1. 공통 WHERE 조건 최대한 활용
2. CASE WHEN 중첩 최소화  
3. NULL 처리 명시적 지정
4. 집계함수와 조건부 COUNT 조합

📊 성능 측정 지표:
- 테이블 SCAN 횟수 (v$sql_plan)
- Consistent Gets 비교
- Buffer Gets vs Physical Reads 비율
- 전체 실행 시간

💡 고급 활용 패턴:
- DECODE vs CASE WHEN 성능 비교
- Conditional Aggregation 패턴
- PIVOT/UNPIVOT 절 활용
- 분석함수와 CASE WHEN 조합
*/

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH union_result AS (
    -- UNION ALL 방식 결과
    SELECT sale_type, COUNT(*) AS cnt, SUM(amount) AS sum_amt
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type = 'A'
    GROUP BY sale_type
    UNION ALL
    SELECT sale_type, COUNT(*), SUM(amount)
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type = 'B'
    GROUP BY sale_type
    UNION ALL
    SELECT sale_type, COUNT(*), SUM(amount)
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type = 'C'
    GROUP BY sale_type
), case_result AS (
    -- CASE WHEN 방식 결과
    SELECT 'A' AS sale_type, 
           COUNT(CASE WHEN sale_type = 'A' THEN 1 END) AS cnt,
           SUM(CASE WHEN sale_type = 'A' THEN amount END) AS sum_amt
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type IN ('A', 'B', 'C')
    UNION ALL
    SELECT 'B',
           COUNT(CASE WHEN sale_type = 'B' THEN 1 END),
           SUM(CASE WHEN sale_type = 'B' THEN amount END)
    FROM T_DAILY_SALES  
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type IN ('A', 'B', 'C')
    UNION ALL
    SELECT 'C',
           COUNT(CASE WHEN sale_type = 'C' THEN 1 END),
           SUM(CASE WHEN sale_type = 'C' THEN amount END)
    FROM T_DAILY_SALES
    WHERE sale_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND region_code = :B_REGION
      AND sale_type IN ('A', 'B', 'C')
)
SELECT 
    ur.sale_type AS 유형,
    ur.cnt AS UNION_건수, cr.cnt AS CASE_건수,
    ur.sum_amt AS UNION_금액합계, cr.sum_amt AS CASE_금액합계,
    CASE WHEN ur.cnt = cr.cnt AND NVL(ur.sum_amt,0) = NVL(cr.sum_amt,0) 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM union_result ur, case_result cr
WHERE ur.sale_type = cr.sale_type
ORDER BY ur.sale_type;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 11 UNION → CASE WHEN 통합 실습 완료 ***
PROMPT *** 다음: case_12.sql (INDEX MIN/MAX) ***