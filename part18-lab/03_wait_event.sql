-- ============================================================
-- Part 18 실습 03: WAIT EVENT 분석 (V$SYSTEM_EVENT)
-- DB_TIME = CPU 시간 + 대기 시간
-- ============================================================
SET LINESIZE 200 PAGESIZE 100

PROMPT ========================================
PROMPT 1. Top 15 Non-Idle WAIT EVENT (누적)
PROMPT ========================================
COL EVENT FOR A45
COL WAIT_CLASS FOR A15
SELECT EVENT, WAIT_CLASS,
       TOTAL_WAITS,
       ROUND(TIME_WAITED / 100, 2) AS TIME_SEC,
       ROUND(AVERAGE_WAIT * 10, 2) AS AVG_WAIT_MS
  FROM V$SYSTEM_EVENT
 WHERE WAIT_CLASS <> 'Idle'
 ORDER BY TIME_WAITED DESC
 FETCH FIRST 15 ROWS ONLY;

PROMPT ========================================
PROMPT 2. WAIT CLASS별 대기 시간 분포
PROMPT    어떤 CLASS가 가장 큰 비중인지 파악
PROMPT ========================================
SELECT WAIT_CLASS,
       SUM(TOTAL_WAITS) AS TOTAL_WAITS,
       ROUND(SUM(TIME_WAITED) / 100, 2) AS TOTAL_SEC,
       ROUND(RATIO_TO_REPORT(SUM(TIME_WAITED)) OVER() * 100, 2) AS PCT
  FROM V$SYSTEM_EVENT
 WHERE WAIT_CLASS NOT IN ('Idle')
 GROUP BY WAIT_CLASS
 ORDER BY TOTAL_SEC DESC;

PROMPT ========================================
PROMPT 3. AWR WAIT EVENT CLASS Trend (최근 3시간)
PROMPT ========================================
SELECT S.SNAP_ID,
       TO_CHAR(S.END_INTERVAL_TIME, 'HH24:MI') AS SNAP_TIME,
       E.WAIT_CLASS,
       (E.TOTAL_WAITS_FG - LAG(E.TOTAL_WAITS_FG) OVER(PARTITION BY E.WAIT_CLASS ORDER BY S.SNAP_ID)) AS DELTA_WAITS,
       ROUND((E.TIME_WAITED_MICRO_FG - LAG(E.TIME_WAITED_MICRO_FG) OVER(PARTITION BY E.WAIT_CLASS ORDER BY S.SNAP_ID))
           / NULLIF((E.TOTAL_WAITS_FG - LAG(E.TOTAL_WAITS_FG) OVER(PARTITION BY E.WAIT_CLASS ORDER BY S.SNAP_ID)), 0)
           / 1000, 2) AS AVG_WAIT_MS
  FROM DBA_HIST_SNAPSHOT S
  JOIN DBA_HIST_SYSTEM_EVENT E ON S.SNAP_ID = E.SNAP_ID AND S.DBID = E.DBID
       AND S.INSTANCE_NUMBER = E.INSTANCE_NUMBER
 WHERE S.END_INTERVAL_TIME > SYSDATE - 3/24
   AND E.WAIT_CLASS NOT IN ('Idle')
   AND S.INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
 ORDER BY S.SNAP_ID, E.WAIT_CLASS;

PROMPT ========================================
PROMPT 4. 주요 I/O WAIT EVENT 평균 대기시간
PROMPT    10ms 이하가 정상
PROMPT ========================================
SELECT EVENT,
       TOTAL_WAITS,
       ROUND(AVERAGE_WAIT * 10, 2) AS AVG_WAIT_MS,
       CASE WHEN AVERAGE_WAIT * 10 > 10 THEN '⚠️ SLOW' ELSE '✅ OK' END AS STATUS
  FROM V$SYSTEM_EVENT
 WHERE EVENT IN ('db file sequential read', 'db file scattered read',
                 'log file sync', 'direct path read', 'direct path read temp')
 ORDER BY TIME_WAITED DESC;
