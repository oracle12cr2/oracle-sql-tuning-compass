-- ============================================================
-- Part 18 실습 00: 환경 점검
-- ============================================================
SET LINESIZE 200 PAGESIZE 100

PROMPT ========================================
PROMPT 1. DB 기본 정보
PROMPT ========================================
SELECT INSTANCE_NUMBER, INSTANCE_NAME, HOST_NAME, STATUS, DATABASE_STATUS
  FROM GV$INSTANCE ORDER BY INSTANCE_NUMBER;

PROMPT ========================================
PROMPT 2. AWR 설정 (스냅샷 주기/보관기간)
PROMPT ========================================
SELECT EXTRACT(DAY FROM SNAP_INTERVAL)*24*60+EXTRACT(HOUR FROM SNAP_INTERVAL)*60+EXTRACT(MINUTE FROM SNAP_INTERVAL) AS "스냅샷주기(분)",
       EXTRACT(DAY FROM RETENTION) AS "보관기간(일)"
  FROM DBA_HIST_WR_CONTROL;

PROMPT ========================================
PROMPT 3. SGA/PGA 크기
PROMPT ========================================
SELECT INST_ID, NAME, ROUND(VALUE/1024/1024) AS MB
  FROM GV$SGA
 WHERE NAME IN ('Fixed Size','Variable Size','Database Buffers','Redo Buffers')
 ORDER BY INST_ID, NAME;

PROMPT ========================================
PROMPT 4. CPU 수
PROMPT ========================================
SELECT STAT_NAME, VALUE FROM V$OSSTAT WHERE STAT_NAME = 'NUM_CPUS';

PROMPT ========================================
PROMPT 5. 최근 스냅샷 5개
PROMPT ========================================
SELECT SNAP_ID, INSTANCE_NUMBER,
       TO_CHAR(END_INTERVAL_TIME, 'MM-DD HH24:MI') AS END_TIME
  FROM DBA_HIST_SNAPSHOT
 WHERE END_INTERVAL_TIME > SYSDATE - 6/24
 ORDER BY SNAP_ID DESC
 FETCH FIRST 15 ROWS ONLY;
