-- ============================================================
-- Part 18 실습 09: 부하 생성기 (실습용)
-- 성능 분석 전에 일부러 부하를 만들어 Trend 변화를 관찰
-- ============================================================

PROMPT ========================================
PROMPT 부하 생성 전 스냅샷 생성
PROMPT ========================================
BEGIN
  DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;
END;
/

PROMPT ========================================
PROMPT 1. CPU 부하 (PL/SQL 루프)
PROMPT ========================================
DECLARE
  v_dummy NUMBER;
BEGIN
  FOR i IN 1..5000000 LOOP
    v_dummy := DBMS_UTILITY.GET_TIME;
  END LOOP;
END;
/

PROMPT ========================================
PROMPT 2. I/O 부하 (Full Table Scan)
PROMPT ========================================
-- DBA_OBJECTS 반복 풀스캔
DECLARE
  v_cnt NUMBER;
BEGIN
  FOR i IN 1..20 LOOP
    SELECT /*+ FULL(o) NO_RESULT_CACHE */ COUNT(*)
      INTO v_cnt
      FROM DBA_OBJECTS o, DBA_OBJECTS o2
     WHERE ROWNUM <= 1000000;
  END LOOP;
END;
/

PROMPT ========================================
PROMPT 3. 하드 파싱 부하 (리터럴 SQL)
PROMPT ========================================
BEGIN
  FOR i IN 1..500 LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM DUAL WHERE 1=' || i;
  END LOOP;
END;
/

PROMPT ========================================
PROMPT 부하 생성 후 스냅샷 생성
PROMPT ========================================
BEGIN
  DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;
END;
/

PROMPT ========================================
PROMPT 완료! 이제 08_full_trend.sql로 변화를 확인하세요.
PROMPT 또는 AWR Report로 정상 구간 vs 부하 구간 비교.
PROMPT ========================================
