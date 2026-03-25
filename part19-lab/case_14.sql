-- =============================================================================
-- Case 14: JOIN 순서/방법 최적화
-- 핵심 튜닝 기법: LEADING 힌트를 통한 최적 JOIN 순서 및 방법 지정
-- 관련 단원: JOIN
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE TB_EQ_RT_RS CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_EQQ_RT_RS CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_PAR_ST_RS CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_EQ_MT_RS CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_EQ_MT_PP CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- TB_EQ_MT_PP 테이블 생성 (장비 모델 정보)
CREATE TABLE TB_EQ_MT_PP AS
SELECT 
    'EQ' || LPAD(rownum, 6, '0') AS RWID,
    CASE MOD(rownum, 10)
        WHEN 0 THEN 'MODEL_A'
        WHEN 1 THEN 'MODEL_B'
        WHEN 2 THEN 'MODEL_C'
        WHEN 3 THEN 'MODEL_D'
        WHEN 4 THEN 'MODEL_E'
        WHEN 5 THEN 'MODEL_F'
        ELSE 'MODEL_G'
    END AS MOD_NAME,
    'PROP' || MOD(rownum, 100) AS MOD_PROP,
    CASE MOD(rownum, 5) WHEN 0 THEN 'N' ELSE 'Y' END AS USE_YN,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS REG_DATE
FROM dual
CONNECT BY rownum <= 50000;

-- TB_EQ_MT_RS 테이블 생성 (장비 메타 정보)
CREATE TABLE TB_EQ_MT_RS AS
SELECT 
    'MT' || LPAD(rownum, 6, '0') AS RWID,
    'EQ' || LPAD(MOD(rownum, 50000) + 1, 6, '0') AS EQP_RAWID,
    CASE MOD(rownum, 8)
        WHEN 0 THEN 'MODEL_A'
        WHEN 1 THEN 'MODEL_B'
        WHEN 2 THEN 'MODEL_C'
        WHEN 3 THEN 'MODEL_D'
        ELSE 'MODEL_E'
    END AS MOD_NAME,
    'META_PROP_' || MOD(rownum, 200) AS MOD_PROP,
    CASE MOD(rownum, 4) WHEN 0 THEN 'N' ELSE 'Y' END AS ACTIVE_YN
FROM dual
CONNECT BY rownum <= 200000;

-- TB_EQQ_RT_RS 테이블 생성 (장비 라우팅 정보)
CREATE TABLE TB_EQQ_RT_RS AS
SELECT 
    'RT' || LPAD(rownum, 6, '0') AS RWID,
    'MT' || LPAD(MOD(rownum, 200000) + 1, 6, '0') AS EQP_RAWID,
    'RP' || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS RP_ID,
    'NET' || MOD(rownum, 50) AS NETWORK_ID,
    CASE MOD(rownum, 3) WHEN 0 THEN 'N' ELSE 'Y' END AS ENABLE_YN
FROM dual
CONNECT BY rownum <= 800000;

-- TB_EQ_RT_RS 테이블 생성 (장비 실시간 상태)
CREATE TABLE TB_EQ_RT_RS AS
SELECT 
    'EQ_RT' || LPAD(rownum, 8, '0') AS EQ_RP_RWID,
    'RT' || LPAD(MOD(rownum, 800000) + 1, 6, '0') AS RWID,  -- TB_EQQ_RT_RS 참조
    'PRM' || LPAD(MOD(rownum, 500000) + 1, 6, '0') AS PRM_RWID,
    'ST' || LPAD(MOD(rownum, 100), 3, '0') AS ST_NAME,
    ROUND(DBMS_RANDOM.VALUE(0, 100), 2) AS TAR,
    CASE MOD(rownum, 4) WHEN 0 THEN 'ERROR' ELSE 'NORMAL' END AS STATUS,
    SYSDATE - DBMS_RANDOM.VALUE(0, 30) AS UPD_TIME
FROM dual
CONNECT BY rownum <= 1500000;

-- TB_PAR_ST_RS 테이블 생성 (파라미터 상태)
CREATE TABLE TB_PAR_ST_RS AS
SELECT 
    'PRM' || LPAD(rownum, 6, '0') AS RWID,
    'ALIAS_' || MOD(rownum, 1000) AS ALI,
    ROUND(DBMS_RANDOM.VALUE(0, 1000), 3) AS GRA,
    CASE MOD(rownum, 5) WHEN 0 THEN 'N' ELSE 'Y' END AS EP_YN,
    'PARAM_TYPE_' || MOD(rownum, 20) AS PARAM_TYPE
FROM dual
CONNECT BY rownum <= 500000;

-- PK 및 INDEX 생성
ALTER TABLE TB_EQ_MT_PP ADD CONSTRAINT PK_TB_EQ_MT_PP PRIMARY KEY (RWID);
ALTER TABLE TB_EQ_MT_RS ADD CONSTRAINT PK_TB_EQ_MT_RS PRIMARY KEY (RWID);
ALTER TABLE TB_EQQ_RT_RS ADD CONSTRAINT PK_TB_EQQ_RT_RS PRIMARY KEY (RWID);
ALTER TABLE TB_EQ_RT_RS ADD CONSTRAINT PK_TB_EQ_RT_RS PRIMARY KEY (EQ_RP_RWID);
ALTER TABLE TB_PAR_ST_RS ADD CONSTRAINT PK_TB_PAR_ST_RS PRIMARY KEY (RWID);

-- 조회용 INDEX 생성
CREATE INDEX TB_EQ_MT_PP_IX1 ON TB_EQ_MT_PP (MOD_NAME);
CREATE INDEX TB_EQ_MT_RS_IX1 ON TB_EQ_MT_RS (EQP_RAWID, MOD_NAME);
CREATE INDEX TB_EQQ_RT_RS_IX1 ON TB_EQQ_RT_RS (EQP_RAWID, RP_ID);
CREATE INDEX TB_EQ_RT_RS_IX1 ON TB_EQ_RT_RS (RWID, PRM_RWID);
CREATE INDEX TB_PAR_ST_RS_IX1 ON TB_PAR_ST_RS (ALI, EP_YN);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_EQ_MT_PP');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_EQ_MT_RS');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_EQQ_RT_RS');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_EQ_RT_RS');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_PAR_ST_RS');

-- 데이터 분포 확인
SELECT 'TB_EQ_RT_RS' 테이블명, COUNT(*) 건수 FROM TB_EQ_RT_RS
UNION ALL
SELECT 'TB_EQQ_RT_RS', COUNT(*) FROM TB_EQQ_RT_RS
UNION ALL
SELECT 'TB_PAR_ST_RS', COUNT(*) FROM TB_PAR_ST_RS
UNION ALL
SELECT 'TB_EQ_MT_RS', COUNT(*) FROM TB_EQ_MT_RS
UNION ALL
SELECT 'TB_EQ_MT_PP', COUNT(*) FROM TB_EQ_MT_PP;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE MOD_NAME_VAR VARCHAR2(20);
VARIABLE RP_ID_VAR VARCHAR2(10);
VARIABLE NOT_LIKE_VAR VARCHAR2(20);

EXEC :MOD_NAME_VAR := 'MODEL_A';
EXEC :RP_ID_VAR := 'RP0001';
EXEC :NOT_LIKE_VAR := 'TEST%';

-- 튜닝 전 SQL (비효율적인 JOIN 순서)
-- 옵티마이저가 비효율적인 순서로 JOIN을 수행
SELECT 
    E.MOD_NAME,
    A.ST_NAME,
    C.ALI,
    A.TAR,
    C.GRA,
    C.EP_YN,
    D.MOD_NAME AS MT_MOD_NAME,
    D.MOD_PROP
FROM TB_EQ_RT_RS A,
     TB_EQQ_RT_RS B,
     TB_PAR_ST_RS C,
     TB_EQ_MT_RS D,
     TB_EQ_MT_PP E
WHERE A.EQ_RP_RWID = B.RWID           -- 실시간상태 ↔ 라우팅정보
  AND A.PRM_RWID = C.RWID             -- 실시간상태 ↔ 파라미터상태
  AND B.EQP_RAWID = D.RWID            -- 라우팅정보 ↔ 메타정보
  AND D.EQP_RAWID = E.RWID            -- 메타정보 ↔ 장비모델
  AND E.MOD_NAME = :MOD_NAME_VAR      -- 필터링 조건
  AND B.RP_ID = :RP_ID_VAR            -- 필터링 조건
  AND B.RP_ID NOT LIKE :NOT_LIKE_VAR  -- 필터링 조건
  AND A.STATUS = 'NORMAL'             -- 필터링 조건
ORDER BY A.ST_NAME, C.ALI;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (최적 JOIN 순서 지정)
-- LEADING 힌트로 필터링 조건이 있는 테이블부터 JOIN
SELECT /*+ 
    LEADING(E D B A C) 
    USE_NL(E D B A)
    USE_HASH(C)
    INDEX(E TB_EQ_MT_PP_IX1)
    INDEX(B TB_EQQ_RT_RS_IX1)
    INDEX(A TB_EQ_RT_RS_IX1)
*/
    E.MOD_NAME,
    A.ST_NAME,
    C.ALI,
    A.TAR,
    C.GRA,
    C.EP_YN,
    D.MOD_NAME AS MT_MOD_NAME,
    D.MOD_PROP
FROM TB_EQ_RT_RS A,
     TB_EQQ_RT_RS B,
     TB_PAR_ST_RS C,
     TB_EQ_MT_RS D,
     TB_EQ_MT_PP E
WHERE A.EQ_RP_RWID = B.RWID           -- 실시간상태 ↔ 라우팅정보
  AND A.PRM_RWID = C.RWID             -- 실시간상태 ↔ 파라미터상태  
  AND B.EQP_RAWID = D.RWID            -- 라우팅정보 ↔ 메타정보
  AND D.EQP_RAWID = E.RWID            -- 메타정보 ↔ 장비모델
  AND E.MOD_NAME = :MOD_NAME_VAR      -- 필터링 조건 (선행)
  AND B.RP_ID = :RP_ID_VAR            -- 필터링 조건 (선행)
  AND B.RP_ID NOT LIKE :NOT_LIKE_VAR  -- 필터링 조건 (선행)
  AND A.STATUS = 'NORMAL'             -- 필터링 조건
ORDER BY A.ST_NAME, C.ALI;

PROMPT
PROMPT ========================================
PROMPT 4. JOIN 순서 최적화 분석
PROMPT ========================================

-- 각 테이블별 필터링 효과 확인
SELECT '1_TB_EQ_MT_PP' 단계, COUNT(*) 건수 
FROM TB_EQ_MT_PP E 
WHERE E.MOD_NAME = :MOD_NAME_VAR

UNION ALL

SELECT '2_TB_EQ_MT_RS' 단계, COUNT(*) 건수
FROM TB_EQ_MT_PP E, TB_EQ_MT_RS D
WHERE D.EQP_RAWID = E.RWID
  AND E.MOD_NAME = :MOD_NAME_VAR

UNION ALL

SELECT '3_TB_EQQ_RT_RS' 단계, COUNT(*) 건수  
FROM TB_EQ_MT_PP E, TB_EQ_MT_RS D, TB_EQQ_RT_RS B
WHERE D.EQP_RAWID = E.RWID
  AND B.EQP_RAWID = D.RWID
  AND E.MOD_NAME = :MOD_NAME_VAR
  AND B.RP_ID = :RP_ID_VAR
  AND B.RP_ID NOT LIKE :NOT_LIKE_VAR

UNION ALL

SELECT '4_TB_EQ_RT_RS' 단계, COUNT(*) 건수
FROM TB_EQ_MT_PP E, TB_EQ_MT_RS D, TB_EQQ_RT_RS B, TB_EQ_RT_RS A
WHERE D.EQP_RAWID = E.RWID
  AND B.EQP_RAWID = D.RWID  
  AND A.EQ_RP_RWID = B.RWID
  AND E.MOD_NAME = :MOD_NAME_VAR
  AND B.RP_ID = :RP_ID_VAR
  AND B.RP_ID NOT LIKE :NOT_LIKE_VAR
  AND A.STATUS = 'NORMAL'

UNION ALL

SELECT '5_TB_PAR_ST_RS' 단계, COUNT(*) 건수
FROM TB_EQ_MT_PP E, TB_EQ_MT_RS D, TB_EQQ_RT_RS B, TB_EQ_RT_RS A, TB_PAR_ST_RS C
WHERE D.EQP_RAWID = E.RWID
  AND B.EQP_RAWID = D.RWID
  AND A.EQ_RP_RWID = B.RWID  
  AND A.PRM_RWID = C.RWID
  AND E.MOD_NAME = :MOD_NAME_VAR
  AND B.RP_ID = :RP_ID_VAR
  AND B.RP_ID NOT LIKE :NOT_LIKE_VAR
  AND A.STATUS = 'NORMAL'

ORDER BY 단계;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 대용량 테이블들의 비효율적인 JOIN 순서
    - 필터링 조건이 있는 테이블이 후순위로 밀려남
    - 많은 건수가 NL JOIN 후 마지막에 대부분 필터링
    - 불필요한 대량 중간 결과 생성
 
 2. JOIN 순서 최적화 전략:
    - 필터링 조건이 강한 테이블을 선행으로 배치
    - 선택도(selectivity)가 높은 조건부터 적용
    - 작은 결과를 만드는 테이블부터 JOIN
    - 카디널리티를 고려한 순서 조정
 
 3. 최적 JOIN 순서 (E→D→B→A→C):
    - E (TB_EQ_MT_PP): MOD_NAME 필터로 대폭 축소
    - D (TB_EQ_MT_RS): E와 1:N JOIN, 비교적 소량
    - B (TB_EQQ_RT_RS): RP_ID 필터로 추가 축소
    - A (TB_EQ_RT_RS): STATUS 필터로 최종 축소  
    - C (TB_PAR_ST_RS): 큰 테이블이므로 HASH JOIN
 
 4. 힌트 활용:
    - LEADING(E D B A C): 명시적 JOIN 순서 지정
    - USE_NL(E D B A): 선택적 소량 JOIN은 NL JOIN
    - USE_HASH(C): 대용량 마지막 JOIN은 HASH JOIN
    - INDEX(): 적절한 INDEX 사용 강제
 
 5. JOIN 방법 선택 기준:
    - NL JOIN: 선행 테이블 결과가 적고 후행에 적절한 INDEX
    - HASH JOIN: 큰 테이블끼리 JOIN하거나 대량 결과 예상
    - 메모리 사용량과 I/O 패턴 고려
 
 6. 적용 조건:
    - 여러 테이블이 복잡하게 연결된 JOIN
    - 각 테이블에 다양한 필터링 조건이 있음
    - 옵티마이저가 잘못된 순서를 선택할 때
    - 성능 차이가 현저한 경우
 
 7. 성과:
    - JOIN 중간 결과 최소화
    - 불필요한 대량 필터링 제거
    - I/O 및 CPU 사용량 대폭 감소
    - 실행 시간 단축
*/

-- 추가 검증: MOD_NAME별 분포 확인
SELECT MOD_NAME, COUNT(*) 건수
FROM TB_EQ_MT_PP
GROUP BY MOD_NAME
ORDER BY 건수 DESC;

-- RP_ID별 분포 확인 (상위 20개)
SELECT RP_ID, COUNT(*) 건수
FROM TB_EQQ_RT_RS
WHERE ROWNUM <= 20
GROUP BY RP_ID
ORDER BY 건수 DESC;

-- STATUS별 분포 확인
SELECT STATUS, COUNT(*) 건수, ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS 비율
FROM TB_EQ_RT_RS
GROUP BY STATUS
ORDER BY 건수 DESC;

PROMPT
PROMPT ========================================
PROMPT 6. 추가 튜닝 기법
PROMPT ========================================

-- EXISTS를 활용한 대안 (매우 제한적인 조건일 때)
SELECT 
    E.MOD_NAME,
    A.ST_NAME,
    C.ALI,
    A.TAR,
    C.GRA,
    C.EP_YN,
    D.MOD_NAME AS MT_MOD_NAME,
    D.MOD_PROP
FROM TB_EQ_MT_PP E
WHERE E.MOD_NAME = :MOD_NAME_VAR
  AND EXISTS (
      SELECT 1 
      FROM TB_EQ_MT_RS D,
           TB_EQQ_RT_RS B,
           TB_EQ_RT_RS A,
           TB_PAR_ST_RS C
      WHERE D.EQP_RAWID = E.RWID
        AND B.EQP_RAWID = D.RWID
        AND A.EQ_RP_RWID = B.RWID
        AND A.PRM_RWID = C.RWID
        AND B.RP_ID = :RP_ID_VAR
        AND B.RP_ID NOT LIKE :NOT_LIKE_VAR
        AND A.STATUS = 'NORMAL'
  );

-- 인라인뷰를 활용한 단계별 필터링
SELECT /*+ LEADING(filtered_e filtered_db filtered_a) */
    filtered_e.MOD_NAME,
    filtered_a.ST_NAME,
    C.ALI,
    filtered_a.TAR,
    C.GRA,
    C.EP_YN,
    filtered_db.MT_MOD_NAME,
    filtered_db.MOD_PROP
FROM (
    -- 1단계: E + D + B 필터링
    SELECT E.RWID, E.MOD_NAME, D.MOD_NAME AS MT_MOD_NAME, D.MOD_PROP, B.RWID AS B_RWID
    FROM TB_EQ_MT_PP E,
         TB_EQ_MT_RS D,
         TB_EQQ_RT_RS B
    WHERE D.EQP_RAWID = E.RWID
      AND B.EQP_RAWID = D.RWID
      AND E.MOD_NAME = :MOD_NAME_VAR
      AND B.RP_ID = :RP_ID_VAR
      AND B.RP_ID NOT LIKE :NOT_LIKE_VAR
) filtered_db,
(
    -- 2단계: A 테이블 필터링
    SELECT EQ_RP_RWID, PRM_RWID, ST_NAME, TAR
    FROM TB_EQ_RT_RS
    WHERE STATUS = 'NORMAL'
) filtered_a,
TB_PAR_ST_RS C
WHERE filtered_a.EQ_RP_RWID = filtered_db.B_RWID
  AND filtered_a.PRM_RWID = C.RWID
ORDER BY filtered_a.ST_NAME, C.ALI;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 14 JOIN 순서/방법 최적화 실습 완료 ***