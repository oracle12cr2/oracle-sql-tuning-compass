-- ============================================================
-- Part 18 실습 07: AWR / ASH / ADDM Report 생성
-- ============================================================
SET LINESIZE 200 PAGESIZE 100

PROMPT ========================================
PROMPT 1. 최근 스냅샷 목록 (Report용 SNAP_ID 확인)
PROMPT ========================================
SELECT SNAP_ID, INSTANCE_NUMBER,
       TO_CHAR(BEGIN_INTERVAL_TIME, 'MM-DD HH24:MI') AS BEGIN_TIME,
       TO_CHAR(END_INTERVAL_TIME, 'MM-DD HH24:MI') AS END_TIME
  FROM DBA_HIST_SNAPSHOT
 WHERE END_INTERVAL_TIME > SYSDATE - 6/24
   AND INSTANCE_NUMBER = (SELECT INSTANCE_NUMBER FROM V$INSTANCE)
 ORDER BY SNAP_ID DESC;

PROMPT ========================================
PROMPT 2. AWR HTML Report 생성
PROMPT    아래 &begin_snap, &end_snap을 위에서 확인한 SNAP_ID로 변경
PROMPT ========================================
PROMPT -- 실행 예시:
PROMPT -- @?/rdbms/admin/awrrpt.sql
PROMPT -- 또는 아래 쿼리로 직접 생성:
PROMPT --
PROMPT -- SELECT OUTPUT FROM TABLE(
PROMPT --   DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(
PROMPT --     (SELECT DBID FROM V$DATABASE),
PROMPT --     (SELECT INSTANCE_NUMBER FROM V$INSTANCE),
PROMPT --     &begin_snap, &end_snap));

PROMPT ========================================
PROMPT 3. AWR 수집 주기 변경 (10분 권장)
PROMPT    현재 30분 → 10분으로 변경 시:
PROMPT ========================================
PROMPT -- BEGIN
PROMPT --   DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(
PROMPT --     retention => 7 * 24 * 60,
PROMPT --     interval  => 10);
PROMPT -- END;
PROMPT -- /

PROMPT ========================================
PROMPT 4. 수동 스냅샷 생성 (부하 테스트 전/후)
PROMPT ========================================
PROMPT -- BEGIN
PROMPT --   DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;
PROMPT -- END;
PROMPT -- /
