-- =============================================================================
-- Case 07: 실행 계획 분리 (OPTIONAL 바인드 변수 대응)
-- 핵심 튜닝 기법: UNION ALL로 실행 계획 분리하여 INDEX 효율성 확보
-- 관련 단원: 실행계획 분리
-- 공통 데이터 세트: T_LOG 테이블 사용  
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
PROMPT 1. 실행 계획 분리 시나리오 설명
PROMPT ========================================

/*
실행 계획 분리 개념:
- Optional 조건이 있는 SQL에서 각 경우별로 최적 실행계획 수립
- UNION ALL을 사용하여 조건별로 다른 INDEX 활용
- 바인드 변수 Peeking 문제 해결

시나리오: 시스템 로그 조회 (조건별 최적화 필요)
- 필수 조건: 날짜 범위
- 선택 조건1: category (CPU/IO/MEM) - 값이 있으면 매우 선택적
- 선택 조건2: status - 값이 있으면 필터 효과 높음

문제점: 하나의 SQL로 모든 경우를 커버하면 어정쩡한 실행계획
해결책: 조건별로 SQL 분리하여 각각 최적 INDEX 활용
*/

PROMPT  
PROMPT ========================================
PROMPT 2. 데이터 분포 및 INDEX 효율성 분석
PROMPT ========================================

-- 컬럼별 분포 확인 (INDEX 선택성 판단)
SELECT 'category' AS 컬럼명, category AS 값, COUNT(*) AS 건수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_LOG), 2) AS 비율_PCT
FROM T_LOG GROUP BY category
UNION ALL
SELECT 'status', status, COUNT(*),
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_LOG), 2)
FROM T_LOG GROUP BY status  
ORDER BY 1, 4 DESC;

-- INDEX 정보 확인
SELECT index_name, column_name, column_position
FROM user_ind_columns
WHERE table_name = 'T_LOG'
  AND index_name IN ('IDX_LOG_01', 'IDX_LOG_02')
ORDER BY index_name, column_position;

-- 날짜별 분포 확인
SELECT TO_CHAR(log_date, 'YYYY-MM') AS 년월, COUNT(*) AS 건수
FROM T_LOG
GROUP BY TO_CHAR(log_date, 'YYYY-MM')
ORDER BY 1;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (단일 SQL)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_START_DATE DATE;
VARIABLE B_END_DATE DATE;
VARIABLE B_CATEGORY VARCHAR2(20);
VARIABLE B_STATUS VARCHAR2(20);
EXEC :B_START_DATE := DATE '2024-06-01';
EXEC :B_END_DATE := DATE '2024-06-30';
EXEC :B_CATEGORY := 'CPU';  -- 때로는 NULL
EXEC :B_STATUS := NULL;     -- 때로는 'ERROR'

-- 튜닝 전 SQL (하나의 SQL로 모든 케이스 처리)
-- Optional 조건으로 인한 실행계획 불안정
SELECT 
    log_id,
    log_date,
    category,
    value,
    session_id,
    status
FROM T_LOG
WHERE log_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND (:B_CATEGORY IS NULL OR category = :B_CATEGORY)
  AND (:B_STATUS IS NULL OR status = :B_STATUS)
  AND value > 50
ORDER BY log_date DESC, log_id;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (UNION ALL 분리)
PROMPT ========================================

-- 튜닝 후 SQL (조건별 실행계획 분리)
-- 각 경우별로 최적 INDEX 활용
SELECT * FROM (
    -- Case 1: category 조건 있음, status 조건 없음
    SELECT /*+ INDEX(t IDX_LOG_01) */
        log_id, log_date, category, value, session_id, status, '1' as case_type
    FROM T_LOG t
    WHERE :B_CATEGORY IS NOT NULL AND :B_STATUS IS NULL
      AND log_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND category = :B_CATEGORY
      AND value > 50
    
    UNION ALL
    
    -- Case 2: category 조건 없음, status 조건 있음  
    SELECT /*+ INDEX(t IDX_LOG_02) */
        log_id, log_date, category, value, session_id, status, '2'
    FROM T_LOG t  
    WHERE :B_CATEGORY IS NULL AND :B_STATUS IS NOT NULL
      AND log_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND status = :B_STATUS
      AND value > 50
    
    UNION ALL
    
    -- Case 3: 둘 다 있음
    SELECT /*+ INDEX(t IDX_LOG_01) */
        log_id, log_date, category, value, session_id, status, '3'
    FROM T_LOG t
    WHERE :B_CATEGORY IS NOT NULL AND :B_STATUS IS NOT NULL  
      AND log_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND category = :B_CATEGORY
      AND status = :B_STATUS
      AND value > 50
    
    UNION ALL
    
    -- Case 4: 둘 다 없음 (날짜 조건만)
    SELECT /*+ INDEX(t IDX_LOG_02) */
        log_id, log_date, category, value, session_id, status, '4'
    FROM T_LOG t
    WHERE :B_CATEGORY IS NULL AND :B_STATUS IS NULL
      AND log_date BETWEEN :B_START_DATE AND :B_END_DATE  
      AND value > 50
)
ORDER BY log_date DESC, log_id;

PROMPT
PROMPT ========================================
PROMPT 5. 실행 계획 분리 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. Optional 조건 문제점:
   - OR 조건, IS NULL 체크로 인한 INDEX 비효율
   - 바인드 변수 Peeking으로 고정된 실행계획
   - 조건별 최적 INDEX 사용 불가

2. UNION ALL 분리 장점:
   - 각 케이스별 전용 실행계획 수립
   - 최적 INDEX 선택 (category → IDX_LOG_01, 날짜만 → IDX_LOG_02)
   - 불필요한 FILTER Operation 제거

3. 분리 기준:
   - 선택성이 크게 다른 조건들
   - INDEX 활용도가 다른 경우
   - 바인드 변수 값에 따라 성능 차이가 큰 경우

4. UNION ALL 주의사항:
   - 중복 데이터 발생 방지 (상호 배타적 조건 필수)
   - 너무 많은 분기는 코드 복잡성 증가
   - 유지보수 비용 고려

5. 성과:
   - 각 시나리오별 최적 INDEX 활용
   - 일관된 성능 보장
   - 바인드 변수 Peeking 문제 해결
*/

-- 각 케이스별 성능 비교
PROMPT
PROMPT === 케이스별 성능 비교 ===

-- Case 1: category 조건만 (선택성 높음)
EXEC :B_CATEGORY := 'CPU'; :B_STATUS := NULL;

SELECT COUNT(*), AVG(value)
FROM T_LOG
WHERE log_date BETWEEN DATE '2024-06-01' AND DATE '2024-06-30'
  AND category = :B_CATEGORY  
  AND value > 50;

-- Case 2: status 조건만 (선택성 보통) 
EXEC :B_CATEGORY := NULL; :B_STATUS := 'ERROR';

SELECT COUNT(*), AVG(value)
FROM T_LOG  
WHERE log_date BETWEEN DATE '2024-06-01' AND DATE '2024-06-30'
  AND status = :B_STATUS
  AND value > 50;

-- Case 3: 둘 다 (매우 선택적)
EXEC :B_CATEGORY := 'CPU'; :B_STATUS := 'ERROR';

SELECT COUNT(*), AVG(value)
FROM T_LOG
WHERE log_date BETWEEN DATE '2024-06-01' AND DATE '2024-06-30'
  AND category = :B_CATEGORY
  AND status = :B_STATUS
  AND value > 50;

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
실행 계획 분리 실무 가이드:

✅ 적용 권장 상황:
- Optional 매개변수가 있는 공통 함수/프로시저
- 조건별 선택성 차이가 10배 이상
- 바인드 변수 값에 따른 성능 편차 심함
- 사용 패턴이 명확하게 구분되는 경우

❌ 적용 비권장 상황:
- 분기 조건이 너무 많은 경우 (>5개)
- 각 케이스 간 성능 차이가 미미한 경우
- 코드 복잡성 대비 성능 이득이 적은 경우

🔧 설계 가이드:
1. 상호 배타적 조건으로 중복 방지
2. 각 분기별 최적 INDEX 힌트 지정
3. 공통 부분은 함수/뷰로 분리
4. 실행 통계 모니터링으로 효과 검증

📊 성능 측정:
- 케이스별 실행시간 편차 확인
- INDEX 사용률 비교 (v$sql_plan)  
- Consistent Gets 감소량
- 사용자 응답시간 개선도

💡 Alternative 기법:
- Dynamic SQL (PL/SQL)
- Function-based Index
- Partitioning 활용
- Materialized View
*/

-- 실행계획 분리 효과 검증
PROMPT
PROMPT === 실행계획 분리 효과 검증 ===

-- 단일 SQL vs 분리 SQL 성능 비교
WITH single_sql AS (
    -- 단일 SQL (category만 조건)
    SELECT COUNT(*) AS cnt
    FROM T_LOG
    WHERE log_date >= DATE '2024-06-01' 
      AND log_date < DATE '2024-07-01'
      AND ('CPU' IS NULL OR category = 'CPU')
      AND value > 50
), split_sql AS (
    -- 분리 SQL 시뮬레이션
    SELECT COUNT(*) AS cnt  
    FROM T_LOG
    WHERE log_date >= DATE '2024-06-01'
      AND log_date < DATE '2024-07-01'  
      AND category = 'CPU'
      AND value > 50
)
SELECT 
    ss.cnt AS 단일SQL_결과,
    sp.cnt AS 분리SQL_결과,
    CASE WHEN ss.cnt = sp.cnt THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM single_sql ss, split_sql sp;

-- 조건별 데이터 분포 (분리 기준 검증)
SELECT 
    CASE WHEN category = 'CPU' AND status = 'ERROR' THEN 'CPU+ERROR'
         WHEN category = 'CPU' THEN 'CPU만'
         WHEN status = 'ERROR' THEN 'ERROR만'  
         ELSE '기타' END AS 조건조합,
    COUNT(*) AS 건수,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_LOG WHERE log_date >= DATE '2024-01-01'), 2) AS 비율_PCT
FROM T_LOG  
WHERE log_date >= DATE '2024-01-01'
GROUP BY 
    CASE WHEN category = 'CPU' AND status = 'ERROR' THEN 'CPU+ERROR'
         WHEN category = 'CPU' THEN 'CPU만'
         WHEN status = 'ERROR' THEN 'ERROR만'
         ELSE '기타' END
ORDER BY COUNT(*) DESC;

SET AUTOTRACE OFF
PROMPT  
PROMPT *** Case 07 실행 계획 분리 실습 완료 ***
PROMPT *** 다음: case_08.sql (JOIN 순서 + 스칼라 서브쿼리) ***