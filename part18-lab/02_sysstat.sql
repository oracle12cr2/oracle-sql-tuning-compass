-- ============================================================
-- Part 18 실습 02: 시스템 통계 (V$SYSSTAT)
-- ============================================================
SET LINESIZE 200 PAGESIZE 100

PROMPT ========================================
PROMPT 1. 핵심 시스템 통계
PROMPT ========================================
COL NAME FOR A35
COL VALUE FOR 999,999,999,999
SELECT NAME, VALUE
  FROM V$SYSSTAT
 WHERE NAME IN ('session logical reads', 'db block gets', 'consistent gets',
                'physical reads', 'physical reads direct',
                'redo size', 'user commits', 'user rollbacks',
                'execute count', 'parse count (total)', 'parse count (hard)',
                'db block changes', 'user calls', 'recursive calls')
 ORDER BY VALUE DESC;

PROMPT ========================================
PROMPT 2. Buffer Cache Hit Ratio (99%+ 목표)
PROMPT ========================================
SELECT ROUND(
  (1 - (SELECT VALUE FROM V$SYSSTAT WHERE NAME = 'physical reads')
       / NULLIF((SELECT VALUE FROM V$SYSSTAT WHERE NAME = 'session logical reads'), 0)
  ) * 100, 2) AS "Buffer Cache Hit %"
FROM DUAL;

PROMPT ========================================
PROMPT 3. 소프트 파싱 비율 (95%+ 목표)
PROMPT ========================================
SELECT ROUND(
  (1 - (SELECT VALUE FROM V$SYSSTAT WHERE NAME = 'parse count (hard)')
       / NULLIF((SELECT VALUE FROM V$SYSSTAT WHERE NAME = 'parse count (total)'), 0)
  ) * 100, 2) AS "Soft Parse %"
FROM DUAL;

PROMPT ========================================
PROMPT 4. PGA 작업 영역 효율성
PROMPT    optimal=100%에 가까울수록 좋음 (onepass/multipass 최소)
PROMPT ========================================
SELECT NAME, VALUE,
       ROUND(RATIO_TO_REPORT(VALUE) OVER() * 100, 2) AS PCT
  FROM V$SYSSTAT
 WHERE NAME LIKE 'workarea executions%';

PROMPT ========================================
PROMPT 5. Redo 생성량 (MB)
PROMPT ========================================
SELECT ROUND(VALUE / 1024 / 1024, 2) AS "Total Redo (MB)"
  FROM V$SYSSTAT WHERE NAME = 'redo size';
