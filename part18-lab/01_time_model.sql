-- ============================================================
-- Part 18 실습 01: 시간 모델 (V$SYS_TIME_MODEL)
-- 핵심: DB_TIME = DB_CPU + Non-Idle Wait Time
-- ============================================================
SET LINESIZE 200 PAGESIZE 100

PROMPT ========================================
PROMPT 1. 현재 시간 모델 통계
PROMPT    DB_TIME이 가장 큰 값. DB_CPU와의 차이 = 대기시간
PROMPT ========================================
COL STAT_NAME FOR A40
COL SECONDS FOR 999,999,990.99
SELECT STAT_NAME, ROUND(VALUE / 1000000, 2) AS SECONDS
  FROM V$SYS_TIME_MODEL
 WHERE STAT_NAME IN ('DB time', 'DB CPU', 'sql execute elapsed time',
                     'parse time elapsed', 'hard parse elapsed time',
                     'background elapsed time', 'PL/SQL execution elapsed time',
                     'connection management call elapsed time')
 ORDER BY VALUE DESC;

PROMPT ========================================
PROMPT 2. DB_TIME 중 CPU 비율 (높을수록 건강)
PROMPT ========================================
SELECT ROUND(
  (SELECT VALUE FROM V$SYS_TIME_MODEL WHERE STAT_NAME = 'DB CPU')
  / NULLIF((SELECT VALUE FROM V$SYS_TIME_MODEL WHERE STAT_NAME = 'DB time'), 0)
  * 100, 2) AS "DB_CPU / DB_TIME %"
FROM DUAL;

PROMPT ========================================
PROMPT 3. AWR 구간별 DB_TIME Trend (최근 3시간)
PROMPT    값이 갑자기 뛰는 구간 = 부하 발생 시점
PROMPT ========================================
SELECT S.SNAP_ID,
       TO_CHAR(S.END_INTERVAL_TIME, 'HH24:MI') AS SNAP_TIME,
       ROUND((T.VALUE - LAG(T.VALUE) OVER(ORDER BY S.SNAP_ID)) / 1000000, 2) AS DB_TIME_DELTA_SEC
  FROM DBA_HIST_SNAPSHOT S
  JOIN DBA_HIST_SYS_TIME_MODEL T ON S.SNAP_ID = T.SNAP_ID AND S.DBID = T.DBID
       AND S.INSTANCE_NUMBER = T.INSTANCE_NUMBER
 WHERE T.STAT_NAME = 'DB time'
   AND S.END_INTERVAL_TIME > SYSDATE - 3/24
   AND S.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
 ORDER BY S.SNAP_ID;

PROMPT ========================================
PROMPT 4. 하드파싱 비율 (시간 모델 기준)
PROMPT    hard parse / parse total = 낮을수록 좋음
PROMPT ========================================
SELECT ROUND(
  (SELECT VALUE FROM V$SYS_TIME_MODEL WHERE STAT_NAME = 'hard parse elapsed time')
  / NULLIF((SELECT VALUE FROM V$SYS_TIME_MODEL WHERE STAT_NAME = 'parse time elapsed'), 0)
  * 100, 2) AS "Hard Parse Time %"
FROM DUAL;
