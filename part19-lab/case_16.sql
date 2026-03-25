-- =============================================================================
-- Case 16: JOIN 순서/방법 + 서브쿼리 최적화
-- 핵심 튜닝 기법: JOIN 순서/방법 변경 + 서브쿼리 최적화로 I/O 대폭 감소
-- 관련 단원: 서브쿼리 + JOIN 최적화
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE TB_MA_HST CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_LT_HST CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_DES_INF CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- TB_MA_HST 테이블 생성 (메인 히스토리 - 대용량)
CREATE TABLE TB_MA_HST AS
SELECT 
    'MA' || LPAD(rownum, 10, '0') AS MA_ID,
    'EQP' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS EQP_ID,
    'STP' || LPAD(MOD(rownum, 50) + 1, 3, '0') AS ORI_STP_ID,
    'LC' || TO_CHAR(SYSDATE, 'YYYYMMDD') || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS MA_LC_ID,
    'LT' || LPAD(MOD(rownum, 200) + 1, 6, '0') AS LT_ID,
    TO_CHAR(SYSDATE - MOD(rownum, 7) / 24, 'YYYYMMDD HH24') || '0000' AS OCR_TIME,
    CASE MOD(rownum, 10)
        WHEN 0 THEN 'moveIn'
        WHEN 1 THEN 'moveOut'
        WHEN 2 THEN 'compIn'
        WHEN 3 THEN 'compOut'
        WHEN 4 THEN 'processStart'
        WHEN 5 THEN 'processEnd'
        WHEN 6 THEN 'inspect'
        WHEN 7 THEN 'rework'
        ELSE 'hold'
    END AS OCR_NAME,
    CASE MOD(rownum, 3)
        WHEN 0 THEN 'P'  -- Production
        WHEN 1 THEN 'S'  -- Sample
        ELSE 'T'         -- Test
    END AS LOT_TYPE,
    ROUND(DBMS_RANDOM.VALUE(1, 10000), 2) AS PROCESS_TIME,
    'USER' || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS REG_USER,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 30)) AS REG_TIME
FROM dual
CONNECT BY rownum <= 5000000;  -- 500만건

-- TB_LT_HST 테이블 생성 (Lot 히스토리 - 중간 규모)
CREATE TABLE TB_LT_HST AS
SELECT 
    'LT' || LPAD(rownum, 6, '0') AS LT_ID,
    'EQP' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS EQP_ID,
    'STP' || LPAD(MOD(rownum, 50) + 1, 3, '0') AS ORI_STP_ID,
    TO_CHAR(SYSDATE - MOD(rownum, 3) / 24, 'YYYYMMDD HH24') || '0000' AS OCR_TIME,
    CASE MOD(rownum, 8)
        WHEN 0 THEN 'TrackIn'
        WHEN 1 THEN 'TrackOut'
        WHEN 2 THEN 'LotStart'
        WHEN 3 THEN 'LotEnd'
        WHEN 4 THEN 'Split'
        WHEN 5 THEN 'Merge'
        WHEN 6 THEN 'Hold'
        ELSE 'Release'
    END AS OCR_NAME,
    CASE MOD(rownum, 4)
        WHEN 0 THEN 'NORMAL'
        WHEN 1 THEN 'URGENT'
        WHEN 2 THEN 'PRIORITY'
        ELSE 'SAMPLE'
    END AS PRIORITY,
    ROUND(DBMS_RANDOM.VALUE(10, 1000)) AS QTY,
    'USER' || LPAD(MOD(rownum, 500) + 1, 4, '0') AS REG_USER,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 7)) AS REG_TIME
FROM dual
CONNECT BY rownum <= 1000000;  -- 100만건

-- TB_DES_INF 테이블 생성 (설정 정보 - 소량)
CREATE TABLE TB_DES_INF AS
SELECT 
    'DB_DES_MONIT' AS GROUP_ID,
    SUBSTR('EQP' || LPAD(rownum, 3, '0'), 4, 3) AS ITEM_ID,  -- 장비 ID의 숫자 부분
    'Equipment ' || rownum AS ITEM_NAME,
    CASE MOD(rownum, 2)
        WHEN 0 THEN 'ACTIVE'
        ELSE 'INACTIVE'
    END AS STATUS,
    'Monitor equipment activity' AS DESCRIPTION,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 100)) AS REG_DATE
FROM dual
CONNECT BY rownum <= 100;

-- PK 및 INDEX 생성
ALTER TABLE TB_MA_HST ADD CONSTRAINT PK_TB_MA_HST PRIMARY KEY (MA_ID);
ALTER TABLE TB_LT_HST ADD CONSTRAINT PK_TB_LT_HST PRIMARY KEY (LT_ID);
ALTER TABLE TB_DES_INF ADD CONSTRAINT PK_TB_DES_INF PRIMARY KEY (GROUP_ID, ITEM_ID);

-- 성능 최적화용 INDEX 생성
-- TB_MA_HST 인덱스
CREATE INDEX TB_MA_HST_IDX1 ON TB_MA_HST (OCR_TIME, OCR_NAME);
CREATE INDEX TB_MA_HST_IDX2 ON TB_MA_HST (OCR_NAME, LOT_TYPE);
CREATE INDEX TB_MA_HST_IDX3 ON TB_MA_HST (EQP_ID, ORI_STP_ID, LT_ID);
CREATE INDEX TB_MA_HST_IDX4 ON TB_MA_HST (OCR_TIME, OCR_NAME, LOT_TYPE);

-- TB_LT_HST 인덱스
CREATE INDEX TB_LT_HST_IDX1 ON TB_LT_HST (OCR_TIME, OCR_NAME);
CREATE INDEX TB_LT_HST_IDX2 ON TB_LT_HST (EQP_ID, ORI_STP_ID, LT_ID);
CREATE INDEX TB_LT_HST_IDX3 ON TB_LT_HST (OCR_NAME, EQP_ID);
CREATE INDEX TB_LT_HST_IDX4 ON TB_LT_HST (OCR_TIME, EQP_ID, OCR_NAME);

-- TB_DES_INF 인덱스
CREATE INDEX TB_DES_INF_IDX1 ON TB_DES_INF (GROUP_ID, ITEM_ID);
CREATE INDEX TB_DES_INF_IDX2 ON TB_DES_INF (GROUP_ID, STATUS);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_MA_HST');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_LT_HST');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_DES_INF');

-- 데이터 분포 확인
SELECT 'TB_MA_HST' 테이블명, COUNT(*) 건수 FROM TB_MA_HST
UNION ALL
SELECT 'TB_LT_HST', COUNT(*) FROM TB_LT_HST
UNION ALL
SELECT 'TB_DES_INF', COUNT(*) FROM TB_DES_INF;

-- OCR_NAME 분포 확인
SELECT OCR_NAME, COUNT(*) 건수
FROM TB_MA_HST
WHERE OCR_NAME IN ('compOut', 'moveOut', 'processEnd')
GROUP BY OCR_NAME
ORDER BY 건수 DESC;

SELECT OCR_NAME, COUNT(*) 건수
FROM TB_LT_HST
WHERE OCR_NAME = 'TrackOut'
GROUP BY OCR_NAME;

-- EQP_ID 패턴 분포 확인
SELECT 
    SUBSTR(EQP_ID, 4, 3) AS EQP_번호,
    COUNT(*) 건수
FROM TB_MA_HST
WHERE SUBSTR(EQP_ID, 4, 3) IN (
    SELECT ITEM_ID FROM TB_DES_INF WHERE GROUP_ID = 'DB_DES_MONIT'
)
AND rownum <= 10
GROUP BY SUBSTR(EQP_ID, 4, 3)
ORDER BY 건수 DESC;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 전 SQL (비효율적 JOIN 순서 + 서브쿼리 최적화 부족)
-- 메인 쿼리와 서브쿼리의 JOIN 순서/방법이 비효율적
SELECT MA_ID, EQP_ID, ORI_STP_ID, SUBSTR(MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST A
WHERE 1 = 1
  AND OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND (EQP_ID, ORI_STP_ID, LT_ID) IN (
      SELECT EQP_ID, ORI_STP_ID, LT_ID
      FROM TB_LT_HST A
      WHERE 1 = 1
        AND OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
        AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
        AND OCR_NAME = 'TrackOut'
        AND SUBSTR(EQP_ID, 4, 3) IN (
            SELECT ITEM_ID 
            FROM TB_DES_INF 
            WHERE GROUP_ID = 'DB_DES_MONIT'
              AND STATUS = 'ACTIVE'
        )
  )
  AND OCR_NAME = 'compOut'
  AND LOT_TYPE = 'S';

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL 1: UNNEST + HASH SEMI JOIN으로 서브쿼리 최적화
SELECT /*+ 
    UNNEST(@SUB1)
    HASH_SJ(@SUB1) 
    SWAP_JOIN_INPUTS(@SUB1 A)
    INDEX(A TB_MA_HST_IDX4)
*/
    MA_ID, EQP_ID, ORI_STP_ID, SUBSTR(MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST A
WHERE 1 = 1
  AND OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND (EQP_ID, ORI_STP_ID, LT_ID) IN (
      SELECT /*+ QB_NAME(SUB1) 
                 INDEX(A TB_LT_HST_IDX4) */
             EQP_ID, ORI_STP_ID, LT_ID
      FROM TB_LT_HST A
      WHERE 1 = 1
        AND OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
        AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
        AND OCR_NAME = 'TrackOut'
        AND SUBSTR(EQP_ID, 4, 3) IN (
            SELECT ITEM_ID 
            FROM TB_DES_INF 
            WHERE GROUP_ID = 'DB_DES_MONIT'
              AND STATUS = 'ACTIVE'
        )
  )
  AND OCR_NAME = 'compOut'
  AND LOT_TYPE = 'S';

-- 튜닝 후 SQL 2: EXISTS로 변환 + 명시적 JOIN
PROMPT
PROMPT ========================================
PROMPT 3-1. 대안 1: EXISTS 변환
PROMPT ========================================

SELECT /*+ 
    USE_NL(A B C)
    INDEX(A TB_MA_HST_IDX4)
    INDEX(B TB_LT_HST_IDX4)  
    INDEX(C TB_DES_INF_IDX2)
*/
    A.MA_ID, A.EQP_ID, A.ORI_STP_ID, SUBSTR(A.MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST A,
     TB_LT_HST B,
     TB_DES_INF C
WHERE A.OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND A.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND A.OCR_NAME = 'compOut'
  AND A.LOT_TYPE = 'S'
  AND B.OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
  AND B.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND B.OCR_NAME = 'TrackOut'
  AND A.EQP_ID = B.EQP_ID
  AND A.ORI_STP_ID = B.ORI_STP_ID
  AND A.LT_ID = B.LT_ID
  AND C.GROUP_ID = 'DB_DES_MONIT'
  AND C.STATUS = 'ACTIVE'
  AND SUBSTR(A.EQP_ID, 4, 3) = C.ITEM_ID;

-- 튜닝 후 SQL 3: WITH절 + 단계별 필터링
PROMPT
PROMPT ========================================
PROMPT 3-2. 대안 2: WITH절 단계별 접근
PROMPT ========================================

WITH ACTIVE_EQUIPMENTS AS (
    SELECT ITEM_ID
    FROM TB_DES_INF
    WHERE GROUP_ID = 'DB_DES_MONIT'
      AND STATUS = 'ACTIVE'
),
TRACKOUT_LOTS AS (
    SELECT /*+ INDEX(LT TB_LT_HST_IDX4) */
           LT.EQP_ID, LT.ORI_STP_ID, LT.LT_ID
    FROM TB_LT_HST LT,
         ACTIVE_EQUIPMENTS AE
    WHERE LT.OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'
      AND LT.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
      AND LT.OCR_NAME = 'TrackOut'
      AND SUBSTR(LT.EQP_ID, 4, 3) = AE.ITEM_ID
)
SELECT /*+ 
    USE_NL(MA TL)
    INDEX(MA TB_MA_HST_IDX4)
*/
    MA.MA_ID, MA.EQP_ID, MA.ORI_STP_ID, SUBSTR(MA.MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST MA,
     TRACKOUT_LOTS TL
WHERE MA.OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND MA.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND MA.OCR_NAME = 'compOut'
  AND MA.LOT_TYPE = 'S'
  AND MA.EQP_ID = TL.EQP_ID
  AND MA.ORI_STP_ID = TL.ORI_STP_ID
  AND MA.LT_ID = TL.LT_ID;

-- 튜닝 후 SQL 4: HASH JOIN 활용
PROMPT
PROMPT ========================================
PROMPT 3-3. 대안 3: HASH JOIN 활용
PROMPT ========================================

SELECT /*+ 
    USE_HASH(A B)
    USE_HASH(B C)
    INDEX(A TB_MA_HST_IDX4)
    INDEX(B TB_LT_HST_IDX4)
    FULL(C)
*/
    A.MA_ID, A.EQP_ID, A.ORI_STP_ID, SUBSTR(A.MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST A,
     TB_LT_HST B,
     TB_DES_INF C
WHERE A.OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND A.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND A.OCR_NAME = 'compOut'
  AND A.LOT_TYPE = 'S'
  AND B.OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
  AND B.OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND B.OCR_NAME = 'TrackOut'
  AND A.EQP_ID = B.EQP_ID
  AND A.ORI_STP_ID = B.ORI_STP_ID
  AND A.LT_ID = B.LT_ID
  AND C.GROUP_ID = 'DB_DES_MONIT'
  AND C.STATUS = 'ACTIVE'
  AND SUBSTR(A.EQP_ID, 4, 3) = C.ITEM_ID;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 메인 쿼리와 서브쿼리의 JOIN 순서가 비효율적
    - IN절 서브쿼리가 복합 조건으로 최적화되지 않음
    - 시간 범위 조건(3시간 vs 1시간)이 다른데 활용하지 못함
    - 내부 서브쿼리까지 3중 중첩으로 복잡도 증가
    - SUBSTR 함수 사용으로 인덱스 활용 제한
 
 2. JOIN 순서/방법 최적화:
    - 시간 범위가 좁은 TB_LT_HST를 먼저 필터링
    - 설정 테이블(TB_DES_INF)은 소량이므로 FULL SCAN 후 HASH JOIN
    - 메인 테이블은 시간 + OCR_NAME + LOT_TYPE 복합 조건 활용
    - JOIN 방법: NL JOIN vs HASH JOIN 선택적 적용
 
 3. 서브쿼리 최적화 기법:
    a) UNNEST + HASH SEMI JOIN:
       - IN절 서브쿼리를 세미조인으로 변환
       - SWAP_JOIN_INPUTS로 build/probe 순서 조정
       - QB_NAME으로 각 쿼리 블록에 명시적 힌트 적용
    
    b) EXISTS 변환:
       - IN절을 명시적 JOIN으로 변환
       - 중복 제거 오버헤드 없음
       - 인덱스 활용도 향상
    
    c) WITH절 단계별 접근:
       - 복잡한 조건을 단계별로 분리
       - 중간 결과를 명시적으로 제어
       - 가독성 향상 + 디버깅 용이
    
    d) HASH JOIN 활용:
       - 큰 테이블간 JOIN은 HASH JOIN
       - 메모리 사용 vs CPU 효율 트레이드오프
       - 병렬 처리 가능성 증가
 
 4. 인덱스 최적화:
    - 복합 인덱스 생성: (OCR_TIME, OCR_NAME, LOT_TYPE)
    - 조건 순서에 맞는 인덱스 컬럼 배치
    - SUBSTR 함수 대신 함수 기반 인덱스 고려 가능
    - 통계 정보 최신화로 옵티마이저 판단 개선
 
 5. 시간 범위 최적화:
    - 메인: 3시간 범위 (넓음)
    - 서브쿼리: 1시간 범위 (좁음)
    - 좁은 범위부터 필터링하여 JOIN 대상 감소
    - 파티션 테이블 활용 시 Partition Pruning 효과
 
 6. 적용 시나리오:
    - 실시간 모니터링 시스템
    - 제조업 장비 추적 시스템
    - 이력 데이터 대용량 조회
    - 다중 조건 복합 쿼리 최적화
 
 7. 성과 측정:
    - Buffer Gets: 논리적 I/O 감소
    - Physical Reads: 물리적 I/O 감소  
    - CPU Time: 연산 시간 단축
    - Elapsed Time: 전체 응답 시간 개선
    - 동시 사용자 처리 능력 향상
*/

-- 데이터 분포 분석을 위한 쿼리들
SELECT '메인_시간범위_3시간' AS 구분, COUNT(*) AS 건수
FROM TB_MA_HST
WHERE OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND OCR_NAME = 'compOut'
  AND LOT_TYPE = 'S'

UNION ALL

SELECT '서브쿼리_시간범위_1시간' AS 구분, COUNT(*) AS 건수
FROM TB_LT_HST
WHERE OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND OCR_NAME = 'TrackOut'

UNION ALL

SELECT '활성_장비수' AS 구분, COUNT(*) AS 건수
FROM TB_DES_INF
WHERE GROUP_ID = 'DB_DES_MONIT'
  AND STATUS = 'ACTIVE';

-- 시간대별 데이터 분포
SELECT 
    SUBSTR(OCR_TIME, 9, 2) AS 시간대,
    SUM(CASE WHEN OCR_NAME = 'compOut' AND LOT_TYPE = 'S' THEN 1 ELSE 0 END) AS 메인조건,
    COUNT(*) AS 전체건수
FROM TB_MA_HST
WHERE OCR_TIME >= TO_CHAR(SYSDATE - 24/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE + 1, 'YYYYMMDD HH24') || '0000'
GROUP BY SUBSTR(OCR_TIME, 9, 2)
ORDER BY 시간대;

-- EQP_ID별 매칭 현황
SELECT 
    SUBSTR(EQP_ID, 4, 3) AS EQP번호,
    COUNT(*) AS MA_HST건수,
    SUM(CASE WHEN EXISTS (
        SELECT 1 FROM TB_DES_INF 
        WHERE GROUP_ID = 'DB_DES_MONIT' 
          AND STATUS = 'ACTIVE' 
          AND ITEM_ID = SUBSTR(EQP_ID, 4, 3)
    ) THEN 1 ELSE 0 END) AS 활성장비매칭건수
FROM TB_MA_HST
WHERE OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND rownum <= 100
GROUP BY SUBSTR(EQP_ID, 4, 3)
ORDER BY 활성장비매칭건수 DESC;

PROMPT
PROMPT ========================================
PROMPT 5. 추가 최적화 기법
PROMPT ========================================

-- 함수 기반 인덱스 예시 (SUBSTR 최적화)
-- CREATE INDEX TB_MA_HST_FBI1 ON TB_MA_HST (SUBSTR(EQP_ID, 4, 3), OCR_TIME, OCR_NAME);
-- CREATE INDEX TB_LT_HST_FBI1 ON TB_LT_HST (SUBSTR(EQP_ID, 4, 3), OCR_TIME, OCR_NAME);

-- 파티션 테이블 예시 (시간 기반 파티셔닝)
/*
CREATE TABLE TB_MA_HST_PARTITIONED (
    ... 컬럼들 ...
)
PARTITION BY RANGE (OCR_TIME) (
    PARTITION P_202401 VALUES LESS THAN ('20240201000000'),
    PARTITION P_202402 VALUES LESS THAN ('20240301000000'),
    ...
);
*/

-- 실시간 성능 모니터링 쿼리
SELECT 
    sql_id,
    child_number,
    plan_hash_value,
    executions,
    elapsed_time/1000000 AS elapsed_sec,
    buffer_gets,
    disk_reads,
    rows_processed,
    ROUND(buffer_gets/GREATEST(executions,1), 2) AS avg_buffer_gets
FROM v$sql
WHERE sql_text LIKE '%TB_MA_HST%'
  AND sql_text LIKE '%TB_LT_HST%'
  AND sql_text NOT LIKE '%v$sql%'
ORDER BY elapsed_time DESC;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 16 JOIN 순서/방법 + 서브쿼리 최적화 실습 완료 ***