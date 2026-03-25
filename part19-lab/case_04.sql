-- =============================================================================
-- Case 04: JPPD (Join Predicate Push Down) 활용
-- 핵심 튜닝 기법: 인라인뷰/UNION ALL VIEW로 조건 침투시켜 불필요한 데이터 제거
-- 관련 단원: JOIN (JPPD)
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP VIEW V_처리내역;
DROP TABLE SCHEMA1_처리내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE SCHEMA2_처리내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 메타기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE BPM_이력전송 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 VIEW 생성
PROMPT ========================================

-- SCHEMA1.처리내역 테이블 생성
CREATE TABLE SCHEMA1_처리내역 AS
SELECT 
    'PRC' || LPAD(rownum, 10, '0') AS 처리아이디,
    'CUS' || LPAD(MOD(rownum-1, 10000) + 1, 8, '0') AS 고객아이디,
    CASE MOD(rownum, 4)
        WHEN 0 THEN '완료'
        WHEN 1 THEN '진행중'
        WHEN 2 THEN '대기'
        ELSE '취소'
    END AS 상태,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 완료시간,
    'TLN' || MOD(rownum, 1000) AS 설명
FROM dual 
CONNECT BY level <= 2000000;  -- 200만건

-- SCHEMA2.처리내역 테이블 생성
CREATE TABLE SCHEMA2_처리내역 AS
SELECT 
    'PRC' || LPAD(rownum + 2000000, 10, '0') AS 처리아이디,
    'CUS' || LPAD(MOD(rownum-1, 10000) + 1, 8, '0') AS 고객아이디,
    CASE MOD(rownum, 4)
        WHEN 0 THEN '완료'
        WHEN 1 THEN '진행중'
        WHEN 2 THEN '대기'
        ELSE '취소'
    END AS 상태,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 완료시간,
    'TLN' || MOD(rownum, 1000) AS 설명
FROM dual 
CONNECT BY level <= 2000000;  -- 200만건

-- UNION ALL VIEW 생성 (총 400만건)
CREATE VIEW V_처리내역 AS
SELECT 처리아이디, 고객아이디, 상태, 완료시간, 설명 FROM SCHEMA1_처리내역
UNION ALL
SELECT 처리아이디, 고객아이디, 상태, 완료시간, 설명 FROM SCHEMA2_처리내역;

-- 메타기본 테이블 생성
CREATE TABLE 메타기본 AS
SELECT 
    'CUS' || LPAD(rownum, 8, '0') AS 인덱스ID,
    '고객' || rownum AS 고객명,
    CASE MOD(rownum, 3) WHEN 0 THEN 'VIP' WHEN 1 THEN '일반' ELSE '휴면' END AS 등급
FROM dual
CONNECT BY level <= 10000;

-- BPM_이력전송 테이블 생성
CREATE TABLE BPM_이력전송 AS
SELECT 
    'PRC' || LPAD(MOD(rownum-1, 3000000) + 1, 10, '0') AS 처리아이디,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 30)) AS 변경시간,
    '처리완료' AS 상태
FROM dual
CONNECT BY level <= 500;  -- 최근 처리 500건

-- INDEX 생성
CREATE INDEX IDX_SCHEMA1_처리내역_01 ON SCHEMA1_처리내역 (처리아이디);
CREATE INDEX IDX_SCHEMA2_처리내역_01 ON SCHEMA2_처리내역 (처리아이디);
CREATE INDEX IDX_BPM_이력전송_01 ON BPM_이력전송 (변경시간);
CREATE INDEX IDX_메타기본_01 ON 메타기본 (인덱스ID);

-- PK 생성
ALTER TABLE SCHEMA1_처리내역 ADD CONSTRAINT PK_SCHEMA1_처리내역 PRIMARY KEY (처리아이디);
ALTER TABLE SCHEMA2_처리내역 ADD CONSTRAINT PK_SCHEMA2_처리내역 PRIMARY KEY (처리아이디);
ALTER TABLE 메타기본 ADD CONSTRAINT PK_메타기본 PRIMARY KEY (인덱스ID);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'SCHEMA1_처리내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'SCHEMA2_처리내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '메타기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'BPM_이력전송');

-- 테이블 크기 확인
SELECT table_name 테이블명, num_rows 건수
FROM user_tables 
WHERE table_name IN ('SCHEMA1_처리내역', 'SCHEMA2_처리내역', '메타기본', 'BPM_이력전송')
ORDER BY num_rows DESC;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획 (JPPD 미발생)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE JobDate VARCHAR2(8);
EXEC :JobDate := TO_CHAR(SYSDATE-1, 'YYYYMMDD');

PRINT JobDate

-- 튜닝 전 SQL (VIEW 전체 SCAN 후 HASH JOIN)
SELECT 
    A.인덱스ID, B.상태,
    TO_CHAR(B.완료시간, 'YYYYMMDDHH24MISS') 완료시간
FROM 메타기본 A,
     (SELECT 
          B.고객아이디, B.처리아이디, B.상태,
          B.완료시간, B.설명
      FROM (
          SELECT 처리아이디
          FROM BPM_이력전송
          WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                            AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
          GROUP BY 처리아이디
      ) A, V_처리내역 B
      WHERE A.처리아이디 = B.처리아이디
        AND B.설명 LIKE 'TLN%'
     ) B
WHERE A.인덱스ID = B.고객아이디;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획 (JPPD 발생)
PROMPT ========================================

-- 튜닝 후 SQL (USE_NL 힌트로 JPPD 유도)
SELECT /*+ USE_NL(A B) */
    A.인덱스ID, B.상태,
    TO_CHAR(B.완료시간, 'YYYYMMDDHH24MISS') 완료시간
FROM 메타기본 A,
     (SELECT /*+ NO_MERGE USE_NL(A B) */
          B.고객아이디, B.처리아이디, B.상태,
          B.완료시간, B.설명
      FROM (
          SELECT 처리아이디
          FROM BPM_이력전송
          WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                            AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
          GROUP BY 처리아이디
      ) A, V_처리내역 B
      WHERE A.처리아이디 = B.처리아이디
        AND B.설명 LIKE 'TLN%'
     ) B
WHERE A.인덱스ID = B.고객아이디;

PROMPT
PROMPT ========================================
PROMPT 4. JPPD 확인용 추가 힌트 테스트
PROMPT ========================================

-- 옵티마이저 파라미터로 JPPD 강제 활성화
SELECT /*+ 
    OPT_PARAM('_optimizer_push_pred_cost_based' 'false')
    USE_NL(A B) 
*/
    A.인덱스ID, B.상태,
    TO_CHAR(B.완료시간, 'YYYYMMDDHH24MISS') 완료시간
FROM 메타기본 A,
     (SELECT /*+ NO_MERGE USE_NL(A B) PUSH_PRED(B) */
          B.고객아이디, B.처리아이디, B.상태,
          B.완료시간, B.설명
      FROM (
          SELECT 처리아이디
          FROM BPM_이력전송
          WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                            AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
          GROUP BY 처리아이디
      ) A, V_처리내역 B
      WHERE A.처리아이디 = B.처리아이디
        AND B.설명 LIKE 'TLN%'
     ) B
WHERE A.인덱스ID = B.고객아이디;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 분석 및 튜닝 포인트
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - V_처리내역 VIEW: UNION ALL로 구성 (400만건)
    - 인라인뷰 결과 건수: 매우 적음 (수십~수백건)
    - JPPD 미발생으로 VIEW 전체 SCAN 후 HASH JOIN
    - 대부분 데이터가 필터링되어 버려짐
 
 2. JPPD(Join Predicate Push Down)란:
    - 외부 쿼리의 JOIN 조건을 내부 VIEW/인라인뷰로 밀어넣는 기법
    - VIEW 전체를 읽지 않고 필요한 데이터만 추출
    - 특히 UNION ALL VIEW에서 효과적
 
 3. JPPD 발생 조건:
    - NL JOIN 사용
    - 적은 건수가 많은 건수와 JOIN
    - VIEW/인라인뷰에 침투 가능한 구조
    - 비용 기반으로 판단 (_optimizer_push_pred_cost_based)
 
 4. 튜닝 방법:
    - USE_NL 힌트로 NL JOIN 강제
    - NO_MERGE 힌트로 VIEW 머지 방지
    - PUSH_PRED 힌트로 JPPD 강제 (필요시)
    - 옵티마이저 파라미터 조정 (필요시)
 
 5. JPPD 확인 방법:
    - 실행계획에서 "VIEW PUSHED PREDICATE" 또는 "UNION ALL PUSHED PREDICATE" 확인
    - Starts 컬럼이 현저히 줄어든 것 확인
    - VIEW 내부 각 테이블의 ACCESS 건수 확인
 
 6. 성과:
    - Buffers: 2,129K → 1,155 (99.95% 개선)
    - 실행 시간: 5분 26초 → 0.02초 (99.99% 개선)
    - PGA 사용량: 1,217K → 0 (100% 개선)
*/

PROMPT
PROMPT ========================================
PROMPT 6. 데이터 분포 확인
PROMPT ========================================

-- BPM_이력전송에서 최근 1일 데이터 건수
SELECT '최근 1일 BPM 이력' 구분, COUNT(*) 건수
FROM BPM_이력전송
WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                   AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
UNION ALL
SELECT 'V_처리내역 전체', COUNT(*) FROM V_처리내역
UNION ALL
SELECT 'TLN으로 시작하는 설명', COUNT(*) FROM V_처리내역 WHERE 설명 LIKE 'TLN%';

-- JOIN 결과 예상 건수
SELECT 'JOIN 예상 결과' 구분, COUNT(*) 건수
FROM (
    SELECT 처리아이디
    FROM BPM_이력전송
    WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                       AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
    GROUP BY 처리아이디
) A, V_처리내역 B
WHERE A.처리아이디 = B.처리아이디
  AND B.설명 LIKE 'TLN%'
  AND rownum <= 1000;  -- 성능상 제한

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 04 JPPD 활용 실습 완료 ***
PROMPT *** 실행계획에서 'UNION ALL PUSHED PREDICATE' 확인하세요! ***