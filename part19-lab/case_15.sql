-- =============================================================================
-- Case 15: JPPD로 인라인뷰 GROUP BY 제거
-- 핵심 튜닝 기법: JOIN PREDICATE PUSH DOWN으로 전체 GROUP BY 연산 제거
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
DROP TABLE TB_RETURN_SLP CASCADE CONSTRAINTS PURGE;
DROP TABLE TB_RETURN_SHT CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- TB_RETURN_SLP 테이블 생성 (반품 전표 - 선행 테이블, 소량)
CREATE TABLE TB_RETURN_SLP AS
SELECT 
    'SLP' || TO_CHAR(SYSDATE, 'YYYYMMDD') || LPAD(rownum, 6, '0') AS SLP_NO,
    CASE MOD(rownum, 5)
        WHEN 0 THEN 'PENDING'
        WHEN 1 THEN 'APPROVED'  
        WHEN 2 THEN 'REJECTED'
        WHEN 3 THEN 'COMPLETED'
        ELSE 'CANCELLED'
    END AS SLP_STAT,
    CASE MOD(rownum, 4)
        WHEN 0 THEN 'TYPE_A'
        WHEN 1 THEN 'TYPE_B'
        WHEN 2 THEN 'TYPE_C'  
        ELSE 'TYPE_D'
    END AS SLP_TYPE,
    'USER' || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS REG_USER,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + MOD(rownum, 120) AS REG_DATE,
    ROUND(DBMS_RANDOM.VALUE(100000, 10000000), -2) AS TOT_AMT,
    'STORE' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS STORE_CD
FROM dual
CONNECT BY rownum <= 50000;  -- 5만건

-- TB_RETURN_SHT 테이블 생성 (반품 상세 내역 - 대용량)
CREATE TABLE TB_RETURN_SHT AS
SELECT 
    rownum AS SEQ_NO,
    'SLP' || TO_CHAR(SYSDATE, 'YYYYMMDD') || LPAD(MOD(rownum, 50000) + 1, 6, '0') AS SLP_NO,
    'MA' || LPAD(MOD(rownum, 10000) + 1, 6, '0') AS MA_CODE,
    TRUNC(DBMS_RANDOM.VALUE(1, 1000)) AS MA_QTY,
    CASE MOD(rownum, 3)
        WHEN 0 THEN 'FG_A'
        WHEN 1 THEN 'FG_B'
        ELSE 'FG_C'
    END AS FG_CODE,
    CASE MOD(rownum, 4)
        WHEN 0 THEN 'STP_1'
        WHEN 1 THEN 'STP_2'
        WHEN 2 THEN 'STP_3'
        ELSE 'STP_4'  
    END AS STP,
    CASE MOD(rownum, 5)
        WHEN 0 THEN 'TYPE_X'
        WHEN 1 THEN 'TYPE_Y'
        WHEN 2 THEN 'TYPE_Z'
        ELSE 'TYPE_W'
    END AS MA_TYPE,
    'PR' || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS PR_CODE,
    ROUND(DBMS_RANDOM.VALUE(100, 100000), -1) AS UNIT_PRICE,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 30)) AS UPD_TIME
FROM dual
CONNECT BY rownum <= 2000000;  -- 200만건 (평균 40건/전표)

-- PK 및 INDEX 생성
ALTER TABLE TB_RETURN_SLP ADD CONSTRAINT PK_TB_RETURN_SLP PRIMARY KEY (SLP_NO);
ALTER TABLE TB_RETURN_SHT ADD CONSTRAINT PK_TB_RETURN_SHT PRIMARY KEY (SEQ_NO);

-- 조회용 INDEX 생성
CREATE INDEX TB_RETURN_SLP_IDX1 ON TB_RETURN_SLP (SLP_STAT);
CREATE INDEX TB_RETURN_SLP_IDX2 ON TB_RETURN_SLP (SLP_TYPE);  
CREATE INDEX TB_RETURN_SLP_IDX3 ON TB_RETURN_SLP (REG_DATE);
CREATE INDEX TB_RETURN_SLP_IDX6 ON TB_RETURN_SLP (SLP_NO);  -- Case 예시용

CREATE INDEX TB_RETURN_SHT_IDX1 ON TB_RETURN_SHT (SLP_NO, MA_CODE);
CREATE INDEX TB_RETURN_SHT_IDX2 ON TB_RETURN_SHT (MA_CODE, MA_TYPE);
CREATE INDEX TB_RETURN_SHT_IDX3 ON TB_RETURN_SHT (SLP_NO, FG_CODE, STP, MA_TYPE, PR_CODE);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_RETURN_SLP');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'TB_RETURN_SHT');

-- 데이터 분포 확인
SELECT 'TB_RETURN_SLP' 테이블명, COUNT(*) 건수 FROM TB_RETURN_SLP
UNION ALL
SELECT 'TB_RETURN_SHT', COUNT(*) FROM TB_RETURN_SHT;

-- JOIN 카디널리티 확인
SELECT 
    COUNT(DISTINCT SLP_NO) AS 전표수,
    COUNT(*) AS 상세수,
    ROUND(COUNT(*) / COUNT(DISTINCT SLP_NO), 1) AS 평균상세수
FROM TB_RETURN_SHT;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정 (특정 조건으로 선행 테이블 결과 276건 가정)
VARIABLE SYS_B_12 VARCHAR2(10);
VARIABLE SYS_B_13 VARCHAR2(10);
VARIABLE SYS_B_21 VARCHAR2(20);
VARIABLE SYS_B_22 VARCHAR2(20);
VARIABLE SYS_B_23 VARCHAR2(20);
VARIABLE SYS_B_24 VARCHAR2(20);

EXEC :SYS_B_12 := '1';
EXEC :SYS_B_13 := '1';
EXEC :SYS_B_21 := 'APPROVED%';  -- 승인된 전표만
EXEC :SYS_B_22 := 'TYPE_A%';   -- 특정 타입만  
EXEC :SYS_B_23 := 'MA%';       -- 자재 코드 패턴
EXEC :SYS_B_24 := 'TYPE_%';    -- 자재 타입 패턴

-- 튜닝 전 SQL (인라인뷰에서 전체 GROUP BY 발생)
-- 선행 결과 276건인데 후행 인라인뷰가 전체 데이터를 GROUP BY
SELECT 
    MS.SLP_NO,
    MS.SLP_STAT,
    MS.SLP_TYPE, 
    MS.TOT_AMT,
    MS.REG_USER,
    MST.MA_CODE,
    MST.MA_QTY,
    MST.FG_CODE,
    MST.STP,
    MST.MA_TYPE,
    MST.PR_CODE
FROM TB_RETURN_SLP MS,
     (SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
             FG_CODE, STP, MA_TYPE, PR_CODE
      FROM TB_RETURN_SHT
      GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE) MST
WHERE :SYS_B_12 = :SYS_B_13
  AND MS.SLP_NO = MST.SLP_NO(+)
  AND MS.SLP_STAT LIKE :SYS_B_21
  AND MS.SLP_TYPE LIKE :SYS_B_22  
  AND MST.MA_CODE LIKE :SYS_B_23
  AND MST.MA_TYPE LIKE :SYS_B_24
ORDER BY MS.SLP_NO DESC, MST.MA_CODE, MST.MA_QTY;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (JPPD 발생으로 선행 건수만 GROUP BY)
-- OPT_PARAM과 힌트로 JPPD 강제 발생
SELECT /*+ 
    OPT_PARAM('_optimizer_cost_based_transformation' 'on')
    OPT_PARAM('_optimizer_push_pred_cost_based' 'true')
    NO_MERGE(MST) 
    USE_NL(MS MST)
    INDEX(MS TB_RETURN_SLP_IDX6)
*/
    MS.SLP_NO,
    MS.SLP_STAT,
    MS.SLP_TYPE,
    MS.TOT_AMT,
    MS.REG_USER,
    MST.MA_CODE,
    MST.MA_QTY,
    MST.FG_CODE,
    MST.STP,
    MST.MA_TYPE,
    MST.PR_CODE
FROM TB_RETURN_SLP MS,
     (SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
             FG_CODE, STP, MA_TYPE, PR_CODE
      FROM TB_RETURN_SHT
      GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE) MST
WHERE :SYS_B_12 = :SYS_B_13
  AND MS.SLP_NO = MST.SLP_NO(+)
  AND MS.SLP_STAT LIKE :SYS_B_21
  AND MS.SLP_TYPE LIKE :SYS_B_22  
  AND MST.MA_CODE LIKE :SYS_B_23
  AND MST.MA_TYPE LIKE :SYS_B_24
ORDER BY MS.SLP_NO DESC, MST.MA_CODE, MST.MA_QTY;

-- 대안 1: EXISTS로 조건을 먼저 체크 후 GROUP BY
PROMPT
PROMPT ========================================
PROMPT 3-1. 대안 1: EXISTS + GROUP BY
PROMPT ========================================

SELECT 
    MS.SLP_NO,
    MS.SLP_STAT,
    MS.SLP_TYPE,
    MS.TOT_AMT,
    MS.REG_USER,
    MST.MA_CODE,
    MST.MA_QTY,
    MST.FG_CODE,
    MST.STP,
    MST.MA_TYPE,
    MST.PR_CODE
FROM TB_RETURN_SLP MS,
     (SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
             FG_CODE, STP, MA_TYPE, PR_CODE
      FROM TB_RETURN_SHT SHT
      WHERE EXISTS (
          SELECT 1 
          FROM TB_RETURN_SLP SLP
          WHERE SLP.SLP_NO = SHT.SLP_NO
            AND SLP.SLP_STAT LIKE :SYS_B_21
            AND SLP.SLP_TYPE LIKE :SYS_B_22
      )
      AND SHT.MA_CODE LIKE :SYS_B_23
      AND SHT.MA_TYPE LIKE :SYS_B_24
      GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE) MST
WHERE :SYS_B_12 = :SYS_B_13
  AND MS.SLP_NO = MST.SLP_NO(+)
  AND MS.SLP_STAT LIKE :SYS_B_21
  AND MS.SLP_TYPE LIKE :SYS_B_22
ORDER BY MS.SLP_NO DESC, MST.MA_CODE, MST.MA_QTY;

-- 대안 2: WITH절을 활용한 단계별 필터링
PROMPT
PROMPT ========================================
PROMPT 3-2. 대안 2: WITH절 활용
PROMPT ========================================

WITH FILTERED_SLP AS (
    SELECT SLP_NO, SLP_STAT, SLP_TYPE, TOT_AMT, REG_USER
    FROM TB_RETURN_SLP
    WHERE :SYS_B_12 = :SYS_B_13
      AND SLP_STAT LIKE :SYS_B_21
      AND SLP_TYPE LIKE :SYS_B_22
),
AGGREGATED_SHT AS (
    SELECT /*+ USE_NL(FS SHT) */
        SHT.SLP_NO, SHT.MA_CODE, SUM(SHT.MA_QTY) MA_QTY,
        SHT.FG_CODE, SHT.STP, SHT.MA_TYPE, SHT.PR_CODE
    FROM FILTERED_SLP FS,
         TB_RETURN_SHT SHT
    WHERE FS.SLP_NO = SHT.SLP_NO
      AND SHT.MA_CODE LIKE :SYS_B_23
      AND SHT.MA_TYPE LIKE :SYS_B_24
    GROUP BY SHT.SLP_NO, SHT.MA_CODE, SHT.FG_CODE, SHT.STP, SHT.MA_TYPE, SHT.PR_CODE
)
SELECT 
    FS.SLP_NO,
    FS.SLP_STAT,
    FS.SLP_TYPE,
    FS.TOT_AMT,
    FS.REG_USER,
    AGG.MA_CODE,
    AGG.MA_QTY,
    AGG.FG_CODE,
    AGG.STP,
    AGG.MA_TYPE,
    AGG.PR_CODE
FROM FILTERED_SLP FS
     LEFT OUTER JOIN AGGREGATED_SHT AGG ON FS.SLP_NO = AGG.SLP_NO
ORDER BY FS.SLP_NO DESC, AGG.MA_CODE, AGG.MA_QTY;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 선행 테이블(TB_RETURN_SLP) 결과가 276건으로 매우 적음
    - 후행 인라인뷰에서 전체 200만건에 대해 GROUP BY 발생
    - 선행 결과가 후행 인라인뷰로 침투하지 못함 (JPPD 미발생)
    - 대부분의 GROUP BY 결과가 버려짐 → 불필요한 PGA 대량 사용
 
 2. JPPD (JOIN PREDICATE PUSH DOWN) 원리:
    - 선행 테이블의 조인 조건을 후행 인라인뷰로 전파
    - 후행 테이블에서 관련된 데이터만 GROUP BY 처리
    - 전체 GROUP BY → 부분 GROUP BY로 범위 축소
    - VIEW PUSHED PREDICATE Operation으로 실행계획에 표시
 
 3. JPPD 발생 조건:
    - 인라인뷰가 GROUP BY나 DISTINCT를 포함
    - 선행 테이블과 후행 인라인뷰 간 조인 컬럼 존재
    - 비용 기반 변환이 활성화되어 있어야 함
    - NO_MERGE 힌트로 인라인뷰 병합 방지
 
 4. JPPD 강제 발생 기법:
    - OPT_PARAM('_optimizer_cost_based_transformation' 'on')
    - OPT_PARAM('_optimizer_push_pred_cost_based' 'true')  
    - NO_MERGE 힌트: 인라인뷰를 별도 처리 단위로 유지
    - USE_NL 힌트: NL JOIN으로 predicate pushing 촉진
 
 5. 대안 방법들:
    - EXISTS: 조건 체크 후 해당 데이터만 GROUP BY
    - WITH절: 단계별 필터링으로 명시적 범위 축소
    - 세미조인: IN 서브쿼리를 이용한 조건 전파
 
 6. 적용 조건:
    - 선행 테이블 결과가 전체 대비 매우 적을 때 
    - 후행 인라인뷰에 GROUP BY/DISTINCT가 있을 때
    - 전체 집계가 불필요하고 부분 집계만 필요할 때
    - PGA 사용량이 큰 문제가 되는 상황
 
 7. 성과:
    - GROUP BY 대상: 전체 200만건 → 276건 관련 데이터만
    - PGA 사용량: 대폭 감소 (전체 GROUP BY 제거)
    - I/O 감소: 불필요한 데이터 처리 제거
    - 실행 시간: 대폭 단축
*/

-- JPPD 확인을 위한 실행계획 분석 쿼리
SELECT operation, options, object_name, cardinality
FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증 및 분석
PROMPT ========================================

-- 선행 테이블 필터링 결과 확인
SELECT COUNT(*) AS 선행결과건수
FROM TB_RETURN_SLP
WHERE SLP_STAT LIKE :SYS_B_21
  AND SLP_TYPE LIKE :SYS_B_22;

-- 전체 GROUP BY vs 부분 GROUP BY 건수 비교
SELECT 
    '전체_GROUP_BY' AS 구분,
    COUNT(*) AS 그룹수,
    SUM(MA_QTY) AS 총수량
FROM (
    SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
           FG_CODE, STP, MA_TYPE, PR_CODE
    FROM TB_RETURN_SHT
    WHERE MA_CODE LIKE :SYS_B_23
      AND MA_TYPE LIKE :SYS_B_24
    GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE
)

UNION ALL

SELECT 
    '부분_GROUP_BY' AS 구분,
    COUNT(*) AS 그룹수,
    SUM(MA_QTY) AS 총수량  
FROM (
    SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
           FG_CODE, STP, MA_TYPE, PR_CODE
    FROM TB_RETURN_SHT SHT
    WHERE EXISTS (
        SELECT 1 
        FROM TB_RETURN_SLP SLP
        WHERE SLP.SLP_NO = SHT.SLP_NO
          AND SLP.SLP_STAT LIKE :SYS_B_21
          AND SLP.SLP_TYPE LIKE :SYS_B_22
    )
    AND SHT.MA_CODE LIKE :SYS_B_23
    AND SHT.MA_TYPE LIKE :SYS_B_24
    GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE
);

-- 전표별 상세 건수 분포 확인
SELECT 
    상세건수범위,
    COUNT(*) AS 전표수,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS 비율
FROM (
    SELECT 
        SLP_NO,
        COUNT(*) AS 상세건수,
        CASE 
            WHEN COUNT(*) <= 10 THEN '10건이하'
            WHEN COUNT(*) <= 50 THEN '11-50건'
            WHEN COUNT(*) <= 100 THEN '51-100건'
            ELSE '100건초과'
        END AS 상세건수범위
    FROM TB_RETURN_SHT
    GROUP BY SLP_NO
)
GROUP BY 상세건수범위
ORDER BY 
    CASE 상세건수범위
        WHEN '10건이하' THEN 1
        WHEN '11-50건' THEN 2
        WHEN '51-100건' THEN 3
        ELSE 4
    END;

-- SLP_STAT, SLP_TYPE별 분포 확인
SELECT SLP_STAT, SLP_TYPE, COUNT(*) 전표수
FROM TB_RETURN_SLP
GROUP BY SLP_STAT, SLP_TYPE
ORDER BY SLP_STAT, SLP_TYPE;

-- MA_CODE, MA_TYPE 패턴별 분포
SELECT 
    CASE WHEN MA_CODE LIKE 'MA%' THEN 'MA패턴' ELSE '기타' END AS MA_CODE_분류,
    CASE WHEN MA_TYPE LIKE 'TYPE_%' THEN 'TYPE패턴' ELSE '기타' END AS MA_TYPE_분류,
    COUNT(*) AS 건수
FROM TB_RETURN_SHT
GROUP BY 
    CASE WHEN MA_CODE LIKE 'MA%' THEN 'MA패턴' ELSE '기타' END,
    CASE WHEN MA_TYPE LIKE 'TYPE_%' THEN 'TYPE패턴' ELSE '기타' END
ORDER BY 건수 DESC;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 15 JPPD로 인라인뷰 GROUP BY 제거 실습 완료 ***