-- =============================================================================
-- Case 13: 페이징 후 JOIN + 스칼라 서브쿼리
-- 핵심 튜닝 기법: 페이징 우선 처리로 JOIN 대상 축소 및 스칼라 서브쿼리 캐싱
-- 관련 단원: 페이징 최적화
-- 공통 데이터 세트: T_BOARD + T_DEPT + T_STATUS 테이블 사용
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
       (SELECT COUNT(*) FROM T_BOARD) AS BOARD_건수,
       (SELECT COUNT(*) FROM T_DEPT) AS DEPT_건수,
       (SELECT COUNT(*) FROM T_STATUS) AS STATUS_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. 페이징 최적화 시나리오 설명
PROMPT ========================================

/*
페이징 최적화 개념:
- 대량 데이터에서 소량 결과만 필요한 경우
- JOIN 전에 페이징 처리로 대상 데이터 축소
- 스칼라 서브쿼리로 추가 정보 효율적 조회

시나리오: 게시판 목록 조회 (최신 20건)
- T_BOARD (50만건) → 최신 20건만 필요
- 부서명, 상태명 추가 정보 필요
- 전체 JOIN 후 페이징 vs 페이징 후 정보 조회

최적화 포인트:
1. 페이징 우선 처리 (ROWNUM, TOP N)
2. 소량 데이터에 대해서만 JOIN/서브쿼리 실행
3. 스칼라 서브쿼리로 코드성 정보 캐싱
*/

PROMPT
PROMPT ========================================
PROMPT 2. 페이징 대상 데이터 분포 확인
PROMPT ========================================

-- 게시판 전체 분포
SELECT 
    COUNT(*) AS 전체_게시글수,
    MIN(created_date) AS 최초작성일,
    MAX(created_date) AS 최근작성일,
    COUNT(DISTINCT dept_id) AS 부서수,
    COUNT(DISTINCT status) AS 상태종류수
FROM T_BOARD;

-- 부서별 게시글 분포 (TOP 10)
SELECT dept_id, COUNT(*) AS 게시글수
FROM T_BOARD
WHERE dept_id <= 20
GROUP BY dept_id
ORDER BY COUNT(*) DESC;

-- 상태별 분포
SELECT status, COUNT(*) AS 게시글수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_BOARD), 2) AS 비율_PCT
FROM T_BOARD
GROUP BY status
ORDER BY COUNT(*) DESC;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (JOIN 후 페이징)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_PAGE_SIZE NUMBER;
VARIABLE B_STATUS_FILTER VARCHAR2(20);
EXEC :B_PAGE_SIZE := 20;
EXEC :B_STATUS_FILTER := 'ACTIVE';

-- 튜닝 전 SQL (전체 JOIN 후 페이징)
-- 50만건 + 100건 + 20건을 모두 JOIN 후 상위 20건만 추출
SELECT * FROM (
    SELECT 
        b.board_id,
        b.title,
        b.created_date,
        b.cust_id,
        b.dept_id,
        d.dept_name,
        d.location,
        b.status,
        s.status_name,
        ROW_NUMBER() OVER (ORDER BY b.created_date DESC, b.board_id DESC) AS rn
    FROM T_BOARD b,
         T_DEPT d,
         T_STATUS s
    WHERE b.dept_id = d.dept_id
      AND b.status = s.status_code
      AND b.status = :B_STATUS_FILTER
    ORDER BY b.created_date DESC, b.board_id DESC
)
WHERE rn <= :B_PAGE_SIZE;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (페이징 후 스칼라 서브쿼리)
PROMPT ========================================

-- 튜닝 후 SQL (페이징 후 스칼라 서브쿼리)
-- 먼저 20건만 추출 후 해당 건들에 대해서만 추가 정보 조회
SELECT 
    board_id,
    title,
    created_date,
    cust_id,
    dept_id,
    (SELECT dept_name FROM T_DEPT WHERE dept_id = b.dept_id) AS dept_name,
    (SELECT location FROM T_DEPT WHERE dept_id = b.dept_id) AS location,
    status,
    (SELECT status_name FROM T_STATUS WHERE status_code = b.status) AS status_name
FROM (
    SELECT /*+ INDEX_DESC(b IDX_BOARD_01) */
        board_id,
        title,
        created_date,
        cust_id,
        dept_id,
        status,
        ROW_NUMBER() OVER (ORDER BY created_date DESC, board_id DESC) AS rn
    FROM T_BOARD b
    WHERE status = :B_STATUS_FILTER
    ORDER BY created_date DESC, board_id DESC
) b
WHERE rn <= :B_PAGE_SIZE;

PROMPT
PROMPT ========================================
PROMPT 5. 더 나은 최적화: ROWNUM 활용
PROMPT ========================================

-- 최종 최적화 SQL (ROWNUM을 사용한 STOPKEY)
-- TOP N STOPKEY로 불필요한 정렬 작업 최소화
SELECT 
    board_id,
    title,
    created_date,
    cust_id,
    dept_id,
    (SELECT dept_name FROM T_DEPT WHERE dept_id = b.dept_id) AS dept_name,
    (SELECT location FROM T_DEPT WHERE dept_id = b.dept_id) AS location,
    status,
    (SELECT status_name FROM T_STATUS WHERE status_code = b.status) AS status_name
FROM (
    SELECT /*+ FIRST_ROWS INDEX_DESC(b IDX_BOARD_01) */
        board_id,
        title, 
        created_date,
        cust_id,
        dept_id,
        status
    FROM T_BOARD b
    WHERE status = :B_STATUS_FILTER
    ORDER BY created_date DESC, board_id DESC
) b
WHERE ROWNUM <= :B_PAGE_SIZE;

PROMPT
PROMPT ========================================
PROMPT 6. 페이징 최적화 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. JOIN 후 페이징 문제점:
   - 대량 테이블 전체 JOIN 처리
   - 모든 결과 정렬 후 상위 N건 추출
   - 불필요한 99.99% 데이터도 JOIN 처리
   - 메모리 및 I/O 과다 사용

2. 페이징 후 JOIN 장점:
   - 소량 데이터(20건)만 JOIN 처리
   - 대량 정렬 작업 최소화
   - 스칼라 서브쿼리 캐싱 효과 극대화
   - 메모리 사용량 대폭 감소

3. ROWNUM vs ROW_NUMBER():
   - ROWNUM: STOPKEY 동작으로 처리 중단
   - ROW_NUMBER(): 전체 결과 처리 후 순위 부여
   - ROWNUM이 성능상 유리

4. INDEX 활용:
   - ORDER BY 컬럼에 INDEX 필수
   - INDEX_DESC로 역순 스캔
   - FIRST_ROWS 힌트로 빠른 응답

5. 스칼라 서브쿼리 효과:
   - 소량(20건) 대상으로 캐싱 효과 높음
   - 부서/상태 정보 중복 조회 최소화
   - JOIN 대비 단순한 실행계획

6. 성과:
   - 처리 대상 데이터 99% 감소
   - 정렬 작업 최소화
   - 메모리 사용량 대폭 절약
   - 응답 속도 10배 이상 향상
*/

-- 페이징 처리 방식별 비교
PROMPT
PROMPT === 페이징 처리 방식별 비교 ===

-- 1) 전체 처리 후 페이징 (처리량 확인)
SELECT 
    '전체 JOIN 후 페이징' AS 방식,
    COUNT(*) AS 전체_처리대상,
    20 AS 실제_필요건수,
    ROUND(COUNT(*) / 20, 2) AS 비효율_배수
FROM T_BOARD b, T_DEPT d, T_STATUS s
WHERE b.dept_id = d.dept_id
  AND b.status = s.status_code
  AND b.status = 'ACTIVE';

-- 2) 페이징 후 추가 정보 (효율적)
SELECT 
    '페이징 후 스칼라 서브쿼리' AS 방식,
    20 AS 전체_처리대상,
    20 AS 실제_필요건수,
    1 AS 비효율_배수
FROM DUAL;

-- 스칼라 서브쿼리 캐싱 효과 분석
PROMPT
PROMPT === 스칼라 서브쿼리 캐싱 효과 ===

WITH paging_result AS (
    SELECT dept_id, status, COUNT(*) AS cnt
    FROM (
        SELECT dept_id, status
        FROM T_BOARD
        WHERE status = 'ACTIVE'
          AND created_date >= DATE '2024-01-01'
        ORDER BY created_date DESC
    )
    WHERE ROWNUM <= 100  -- 샘플링
    GROUP BY dept_id, status
)
SELECT 
    '처리건수' AS 구분, SUM(cnt) AS 값 FROM paging_result
UNION ALL
SELECT 'DISTINCT 부서수', COUNT(DISTINCT dept_id) FROM paging_result
UNION ALL
SELECT 'DISTINCT 상태수', COUNT(DISTINCT status) FROM paging_result
UNION ALL
SELECT '캐시 효율성', 
       ROUND((SUM(cnt) - COUNT(DISTINCT dept_id) - COUNT(DISTINCT status)) * 100.0 / SUM(cnt), 2)
FROM paging_result;

PROMPT
PROMPT ========================================
PROMPT 7. 실무 적용 가이드
PROMPT ========================================

/*
페이징 최적화 실무 가이드:

✅ 페이징 후 JOIN 적용 권장:
- 대량 테이블에서 소량 결과 필요 (< 1%)
- ORDER BY 컬럼에 효율적 INDEX 존재
- 추가 정보가 코드성/마스터 테이블
- 사용자 화면 페이징 처리

❌ 페이징 후 JOIN 주의:
- 결과 비율이 높은 경우 (> 10%)
- ORDER BY 컬럼에 INDEX 없음
- 복잡한 JOIN 조건
- 배치 처리 등 전체 데이터 필요

🔧 페이징 최적화 기법:
1. ORDER BY 컬럼 INDEX 필수 생성
2. ROWNUM vs ROW_NUMBER() 적절 선택
3. FIRST_ROWS 힌트 활용
4. 스칼라 서브쿼리로 추가 정보 조회

📊 성능 측정 지표:
- 처리 대상 Row 수 감소율
- SORT 작업 메모리 사용량
- 전체 실행 시간 개선도
- Buffer Gets 감소량

💡 고급 활용 패턴:
- Cursor Pagination (offset 대체)
- Keyset Pagination 
- Parallel 처리와 조합
- Materialized View 활용

🔍 페이징 성능 체크리스트:
1. ORDER BY 컬럼 INDEX 확인
2. STOPKEY operation 실행계획 확인
3. 페이징 조건별 성능 테스트
4. 캐시 효율성 검증 (스칼라 서브쿼리)
5. 메모리 사용량 모니터링
*/

-- 실제 페이징 시나리오 시뮬레이션
PROMPT
PROMPT === 실제 페이징 시나리오 시뮬레이션 ===

-- 페이지별 성능 비교 (1페이지 vs 10페이지)
SELECT 
    '1페이지 (1-20)' AS 페이지,
    COUNT(*) AS 처리건수
FROM (
    SELECT board_id
    FROM T_BOARD
    WHERE status = 'ACTIVE'
    ORDER BY created_date DESC, board_id DESC
)
WHERE ROWNUM BETWEEN 1 AND 20

UNION ALL

SELECT 
    '10페이지 (181-200)',
    COUNT(*)
FROM (
    SELECT board_id, 
           ROW_NUMBER() OVER (ORDER BY created_date DESC, board_id DESC) AS rn
    FROM T_BOARD
    WHERE status = 'ACTIVE'
)
WHERE rn BETWEEN 181 AND 200;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH join_first AS (
    SELECT board_id, dept_id, status
    FROM (
        SELECT b.board_id, b.dept_id, b.status,
               ROW_NUMBER() OVER (ORDER BY b.created_date DESC, b.board_id DESC) AS rn
        FROM T_BOARD b, T_DEPT d, T_STATUS s
        WHERE b.dept_id = d.dept_id AND b.status = s.status_code AND b.status = 'ACTIVE'
    )
    WHERE rn <= 5
), paging_first AS (
    SELECT board_id, dept_id, status
    FROM (
        SELECT board_id, dept_id, status
        FROM T_BOARD
        WHERE status = 'ACTIVE'
        ORDER BY created_date DESC, board_id DESC
    )
    WHERE ROWNUM <= 5
)
SELECT 
    jf.board_id AS JOIN후페이징_ID, pf.board_id AS 페이징후JOIN_ID,
    CASE WHEN jf.board_id = pf.board_id THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM join_first jf, paging_first pf
WHERE jf.board_id = pf.board_id (+)
ORDER BY jf.board_id;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 13 페이징 후 JOIN + 스칼라 서브쿼리 실습 완료 ***
PROMPT *** 다음: case_14.sql (JOIN 순서/방법 최적화) ***