-- =============================================================================
-- Case 10: WINDOW 함수 + EXISTS
-- 핵심 튜닝 기법: 분석함수로 중복 제거 및 반복 ACCESS 최적화
-- 관련 단원: 분석함수 최적화
-- 공통 데이터 세트: T_LOG 테이블 사용 (LAG/LEAD 분석)
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분, COUNT(*) AS T_LOG_건수 FROM T_LOG;

PROMPT
PROMPT ========================================
PROMPT 1. WINDOW 함수 최적화 시나리오 설명
PROMPT ========================================

/*
WINDOW 함수(분석함수) 최적화 개념:
- 반복적인 Self Join이나 서브쿼리를 분석함수로 대체
- 한 번의 SCAN으로 이전/다음/순위 등 복합 정보 추출
- 정렬 작업 최소화 및 메모리 효율성 개선

시나리오: 시스템 로그 분석
- 각 로그의 이전/다음 값과 비교 (LAG/LEAD)
- 특정 조건을 만족하는 로그만 추출 (EXISTS 조합)
- Self Join 방식 vs Window 함수 방식 비교

최적화 포인트:
- Self Join → Window 함수로 변경
- 중복 정렬 작업 제거
- 메모리 사용량 최적화
*/

PROMPT
PROMPT ========================================
PROMPT 2. 데이터 분포 및 분석함수 적용 영역
PROMPT ========================================

-- 카테고리별 로그 분포
SELECT category, COUNT(*) AS 로그건수,
       MIN(log_date) AS 최초일시, MAX(log_date) AS 최종일시
FROM T_LOG
GROUP BY category
ORDER BY COUNT(*) DESC;

-- 값 변화 패턴 확인 (분석함수 활용 예시)
SELECT category,
       COUNT(*) AS 전체건수,
       COUNT(CASE WHEN 값변화 > 10 THEN 1 END) AS 급변건수,
       ROUND(COUNT(CASE WHEN 값변화 > 10 THEN 1 END) * 100.0 / COUNT(*), 2) AS 급변비율_PCT
FROM (
    SELECT category, value,
           ABS(value - LAG(value, 1, value) OVER (PARTITION BY category ORDER BY log_date)) AS 값변화
    FROM T_LOG
    WHERE log_date >= DATE '2024-06-01'
      AND log_date < DATE '2024-07-01'
)
GROUP BY category
ORDER BY 급변비율_PCT DESC;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (Self Join 방식)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_CATEGORY VARCHAR2(20);
VARIABLE B_START_DATE DATE;
VARIABLE B_END_DATE DATE;
EXEC :B_CATEGORY := 'CPU';
EXEC :B_START_DATE := DATE '2024-06-01';
EXEC :B_END_DATE := DATE '2024-06-30';

-- 튜닝 전 SQL (Self Join으로 이전값과 비교)
-- 같은 테이블을 여러 번 접근하여 이전/다음 값 조회
SELECT 
    t1.log_id,
    t1.log_date,
    t1.category,
    t1.value AS 현재값,
    t2.value AS 이전값,
    t3.value AS 다음값,
    t1.value - NVL(t2.value, t1.value) AS 이전대비변화,
    NVL(t3.value, t1.value) - t1.value AS 다음대비변화,
    t1.session_id,
    t1.status
FROM T_LOG t1
LEFT OUTER JOIN T_LOG t2 ON (
    t2.category = t1.category 
    AND t2.log_date = (
        SELECT MAX(log_date) 
        FROM T_LOG 
        WHERE category = t1.category 
          AND log_date < t1.log_date
          AND log_date >= :B_START_DATE
    )
)
LEFT OUTER JOIN T_LOG t3 ON (
    t3.category = t1.category
    AND t3.log_date = (
        SELECT MIN(log_date)
        FROM T_LOG
        WHERE category = t1.category
          AND log_date > t1.log_date  
          AND log_date <= :B_END_DATE
    )
)
WHERE t1.category = :B_CATEGORY
  AND t1.log_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND t1.value > 70  -- 임계값 초과 건만
ORDER BY t1.log_date, t1.log_id;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (Window 함수)
PROMPT ========================================

-- 튜닝 후 SQL (Window 함수 사용)
-- 한 번의 테이블 SCAN으로 이전/다음 값 추출
SELECT 
    log_id,
    log_date,
    category,
    value AS 현재값,
    LAG(value, 1, value) OVER (
        PARTITION BY category 
        ORDER BY log_date, log_id
    ) AS 이전값,
    LEAD(value, 1, value) OVER (
        PARTITION BY category
        ORDER BY log_date, log_id  
    ) AS 다음값,
    value - LAG(value, 1, value) OVER (
        PARTITION BY category 
        ORDER BY log_date, log_id
    ) AS 이전대비변화,
    LEAD(value, 1, value) OVER (
        PARTITION BY category
        ORDER BY log_date, log_id
    ) - value AS 다음대비변화,
    session_id,
    status
FROM T_LOG
WHERE category = :B_CATEGORY
  AND log_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND value > 70
ORDER BY log_date, log_id;

PROMPT
PROMPT ========================================
PROMPT 5. Window 함수 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. Self Join 문제점:
   - 같은 테이블 3번 접근 (t1, t2, t3)
   - 서브쿼리로 인한 중복 연산
   - 복잡한 JOIN 조건으로 성능 저하
   - INDEX 스캔 반복 발생

2. Window 함수 장점:
   - 테이블 1번 스캔으로 모든 정보 추출
   - PARTITION BY로 그룹별 분석
   - ORDER BY로 순서 지정
   - LAG/LEAD로 이전/다음 값 참조

3. Window 함수 종류:
   - LAG/LEAD: 이전/다음 행 참조
   - ROW_NUMBER/RANK/DENSE_RANK: 순위 함수
   - SUM/COUNT/AVG OVER: 누적/이동 집계
   - FIRST_VALUE/LAST_VALUE: 그룹 내 첫/마지막 값

4. 성능 최적화 효과:
   - 논리적 I/O 대폭 감소 (테이블 ACCESS 1회)
   - SORT 작업 1회로 통합
   - CPU 사용량 감소
   - 메모리 사용량 최적화

5. 실행계획 분석:
   - WINDOW SORT operation 확인
   - TABLE ACCESS 횟수 비교 (3회 → 1회)
   - Hash Join/Nested Loop 제거
*/

-- Window 함수 활용 고급 예시
PROMPT
PROMPT === Window 함수 고급 활용 ===

-- 1) 이동 평균 계산
SELECT 
    log_date,
    category,
    value,
    AVG(value) OVER (
        PARTITION BY category 
        ORDER BY log_date 
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS 이동평균_3일,
    value - AVG(value) OVER (
        PARTITION BY category
        ORDER BY log_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW  
    ) AS 평균대비편차
FROM T_LOG
WHERE category = 'CPU'
  AND log_date >= DATE '2024-06-01'
  AND log_date < DATE '2024-06-10'
ORDER BY log_date;

-- 2) 순위 및 비율 분석
SELECT 
    category,
    session_id,
    value,
    ROW_NUMBER() OVER (PARTITION BY category ORDER BY value DESC) AS 순위,
    RANK() OVER (PARTITION BY category ORDER BY value DESC) AS 공동순위,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY value) AS 백분위순위,
    value / SUM(value) OVER (PARTITION BY category) * 100 AS 비율_PCT
FROM T_LOG
WHERE log_date >= DATE '2024-06-01'
  AND log_date < DATE '2024-06-02'
  AND category IN ('CPU', 'MEM')
ORDER BY category, value DESC;

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
Window 함수 실무 최적화 가이드:

✅ Window 함수 적용 권장 상황:
- Self Join으로 이전/다음 행 참조
- 그룹별 순위/집계 계산
- 이동평균, 누적합계 등 분석
- 복잡한 서브쿼리 대체

❌ Window 함수 주의 상황:  
- 전체 데이터 정렬 필요로 메모리 부족
- PARTITION 크기가 너무 큰 경우
- ORDER BY 컬럼에 INDEX 없는 경우

🔧 Window 함수 최적화 기법:
1. PARTITION BY로 정렬 범위 축소
2. ORDER BY 컬럼에 적절한 INDEX 생성
3. ROWS vs RANGE 윈도우 프레임 선택
4. 불필요한 분석함수 중복 제거

📊 성능 측정 지표:
- WINDOW SORT 메모리 사용량
- TABLE ACCESS 횟수 감소
- 전체 실행 시간 개선
- CPU 사용량 절약

💡 고급 활용 패턴:
- 조건부 Window 함수 (CASE WHEN)
- 다중 Window 함수 조합
- Window 함수 + EXISTS 결합
- Parallel 처리와 조합
*/

-- 성능 비교: Self Join vs Window 함수
PROMPT
PROMPT === 성능 비교 테스트 ===

-- 단순 비교를 위한 건수 확인
SELECT 
    'Self Join 방식(시뮬레이션)' AS 방식,
    COUNT(*) AS 처리_예상건수
FROM T_LOG t1, T_LOG t2, T_LOG t3
WHERE t1.category = 'CPU'
  AND t1.log_date >= DATE '2024-06-01'
  AND t1.log_date < DATE '2024-06-02'
  AND t2.category = t1.category
  AND t3.category = t1.category
  AND ROWNUM <= 1000  -- 샘플링
UNION ALL
SELECT 
    'Window 함수 방식',
    COUNT(*)
FROM T_LOG  
WHERE category = 'CPU'
  AND log_date >= DATE '2024-06-01'
  AND log_date < DATE '2024-06-02';

-- Window 함수 결과 검증
PROMPT
PROMPT === Window 함수 결과 검증 ===

WITH window_result AS (
    SELECT 
        log_id,
        value,
        LAG(value) OVER (PARTITION BY category ORDER BY log_date, log_id) AS lag_value,
        LEAD(value) OVER (PARTITION BY category ORDER BY log_date, log_id) AS lead_value
    FROM T_LOG
    WHERE category = 'CPU'
      AND log_date >= DATE '2024-06-01'  
      AND log_date < DATE '2024-06-02'
      AND ROWNUM <= 10
)
SELECT 
    log_id,
    value AS 현재값,
    lag_value AS 이전값,
    lead_value AS 다음값,
    CASE WHEN lag_value IS NOT NULL THEN value - lag_value END AS 이전대비변화,
    CASE WHEN lead_value IS NOT NULL THEN lead_value - value END AS 다음대비변화
FROM window_result
ORDER BY log_id;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 10 WINDOW 함수 + EXISTS 실습 완료 ***
PROMPT *** 다음: case_11.sql (UNION → CASE WHEN 통합) ***