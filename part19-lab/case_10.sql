-- =============================================================================
-- Case 10: WINDOW 함수 + EXISTS
-- 핵심 튜닝 기법: 분석함수로 중복 제거 및 반복 ACCESS 최적화
-- 관련 단원: JOIN, 서브쿼리, PGA 튜닝
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)  
DROP TABLE 매출데이터 CASCADE CONSTRAINTS PURGE;
DROP TABLE 고객기본정보 CASCADE CONSTRAINTS PURGE;
DROP TABLE 상품정보 CASCADE CONSTRAINTS PURGE;
DROP TABLE 지역정보 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 고객기본정보 테이블 생성
CREATE TABLE 고객기본정보 AS
SELECT 
    'CUST' || LPAD(rownum, 6, '0') AS 고객코드,
    '고객' || rownum AS 고객명,
    CASE MOD(rownum, 4)
        WHEN 0 THEN 'VIP'
        WHEN 1 THEN 'GOLD'
        WHEN 2 THEN 'SILVER'
        ELSE 'BRONZE'
    END AS 고객등급,
    'REGION' || LPAD(MOD(rownum, 50) + 1, 3, '0') AS 지역코드,
    TO_DATE('2020-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 1460)) AS 가입일자,
    'Y' AS 활성여부
FROM dual
CONNECT BY rownum <= 10000;

-- 상품정보 테이블 생성
CREATE TABLE 상품정보 AS
SELECT 
    'PROD' || LPAD(rownum, 4, '0') AS 상품코드,
    '상품' || rownum AS 상품명,
    CASE MOD(rownum, 3)
        WHEN 0 THEN 'A'  -- 고가상품
        WHEN 1 THEN 'B'  -- 중가상품
        ELSE 'C'         -- 저가상품
    END AS 상품등급,
    ROUND(DBMS_RANDOM.VALUE(10000, 1000000), -2) AS 표준가격
FROM dual
CONNECT BY rownum <= 1000;

-- 지역정보 테이블 생성
CREATE TABLE 지역정보 AS
SELECT 
    'REGION' || LPAD(rownum, 3, '0') AS 지역코드,
    '지역' || rownum AS 지역명,
    CASE MOD(rownum, 3)
        WHEN 0 THEN '서울'
        WHEN 1 THEN '경기'
        ELSE '지방'
    END AS 권역명
FROM dual
CONNECT BY rownum <= 100;

-- 매출데이터 테이블 생성 (메인 테이블)
CREATE TABLE 매출데이터 AS
SELECT 
    rownum AS 매출ID,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + MOD(rownum, 365) AS 매출일자,
    'CUST' || LPAD(MOD(rownum, 10000) + 1, 6, '0') AS 고객코드,
    'PROD' || LPAD(MOD(rownum, 1000) + 1, 4, '0') AS 상품코드,
    TRUNC(DBMS_RANDOM.VALUE(1, 10)) AS 수량,
    ROUND(DBMS_RANDOM.VALUE(1000, 100000), -2) AS 매출금액,
    CASE MOD(rownum, 10)
        WHEN 0 THEN 'CANCEL'
        ELSE 'NORMAL'
    END AS 매출상태,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 30)) AS 등록일시
FROM dual
CONNECT BY rownum <= 500000;  -- 50만건

-- PK 및 INDEX 생성
ALTER TABLE 고객기본정보 ADD CONSTRAINT PK_고객기본정보 PRIMARY KEY (고객코드);
ALTER TABLE 상품정보 ADD CONSTRAINT PK_상품정보 PRIMARY KEY (상품코드);
ALTER TABLE 지역정보 ADD CONSTRAINT PK_지역정보 PRIMARY KEY (지역코드);
ALTER TABLE 매출데이터 ADD CONSTRAINT PK_매출데이터 PRIMARY KEY (매출ID);

-- 매출데이터 조회용 INDEX 생성
CREATE INDEX 매출데이터_IX1 ON 매출데이터 (매출일자, 고객코드);
CREATE INDEX 매출데이터_IX2 ON 매출데이터 (고객코드, 매출일자, 매출금액);
CREATE INDEX 매출데이터_IX3 ON 매출데이터 (상품코드, 매출일자);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '고객기본정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '상품정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '지역정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '매출데이터');

-- 데이터 분포 확인
SELECT '매출데이터' 테이블명, COUNT(*) 건수 FROM 매출데이터
UNION ALL
SELECT '고객기본정보', COUNT(*) FROM 고객기본정보
UNION ALL
SELECT '상품정보', COUNT(*) FROM 상품정보
UNION ALL
SELECT '지역정보', COUNT(*) FROM 지역정보;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 시작일자 VARCHAR2(10);
VARIABLE 종료일자 VARCHAR2(10);

EXEC :시작일자 := '20240301';
EXEC :종료일자 := '20240331';

-- 튜닝 전 SQL (UNION으로 동일 테이블 반복 ACCESS)
-- 각 고객의 최고 매출액과 최신 매출일자를 조회하되, SELECT절 참조 컬럼만 다름
SELECT 
    '최고매출' AS 구분,
    C.고객코드,
    C.고객명, 
    C.고객등급,
    R.지역명,
    M.매출금액 AS 금액,
    M.매출일자,
    P.상품명
FROM 매출데이터 M,
     고객기본정보 C,
     상품정보 P,
     지역정보 R
WHERE M.매출일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND M.매출상태 = 'NORMAL'
  AND M.고객코드 = C.고객코드
  AND M.상품코드 = P.상품코드  
  AND C.지역코드 = R.지역코드
  AND M.매출금액 = (
      SELECT MAX(매출금액)
      FROM 매출데이터 M2
      WHERE M2.고객코드 = M.고객코드
        AND M2.매출일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
        AND M2.매출상태 = 'NORMAL'
  )

UNION ALL

SELECT 
    '최신매출' AS 구분,
    C.고객코드,
    C.고객명,
    C.고객등급, 
    R.지역명,
    M.매출금액 AS 금액,
    M.매출일자,
    P.상품명
FROM 매출데이터 M,
     고객기본정보 C,
     상품정보 P,
     지역정보 R
WHERE M.매출일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND M.매출상태 = 'NORMAL'
  AND M.고객코드 = C.고객코드
  AND M.상품코드 = P.상품코드
  AND C.지역코드 = R.지역코드
  AND M.매출일자 = (
      SELECT MAX(매출일자)
      FROM 매출데이터 M2
      WHERE M2.고객코드 = M.고객코드
        AND M2.매출일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
        AND M2.매출상태 = 'NORMAL'
  )

ORDER BY 고객코드, 구분;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (WINDOW 함수 + WITH절 + EXISTS로 최적화)
WITH 매출분석 AS (
    /*+ MATERIALIZE */
    SELECT 
        M.고객코드,
        M.상품코드,
        M.매출금액,
        M.매출일자,
        RANK() OVER (PARTITION BY M.고객코드 ORDER BY M.매출금액 DESC) AS 매출금액_순위,
        RANK() OVER (PARTITION BY M.고객코드 ORDER BY M.매출일자 DESC) AS 매출일자_순위
    FROM 매출데이터 M
    WHERE M.매출일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
      AND M.매출상태 = 'NORMAL'
),
고객별최고매출 AS (
    SELECT 고객코드, 상품코드, 매출금액, 매출일자
    FROM 매출분석
    WHERE 매출금액_순위 = 1
),
고객별최신매출 AS (
    SELECT 고객코드, 상품코드, 매출금액, 매출일자  
    FROM 매출분석
    WHERE 매출일자_순위 = 1
)
SELECT 
    '최고매출' AS 구분,
    C.고객코드,
    C.고객명,
    C.고객등급,
    R.지역명,
    MH.매출금액 AS 금액,
    MH.매출일자,
    P.상품명
FROM 고객별최고매출 MH,
     고객기본정보 C,
     상품정보 P,
     지역정보 R
WHERE MH.고객코드 = C.고객코드
  AND MH.상품코드 = P.상품코드
  AND C.지역코드 = R.지역코드

UNION ALL

SELECT 
    '최신매출' AS 구분,
    C.고객코드,
    C.고객명,
    C.고객등급,
    R.지역명,
    ML.매출금액 AS 금액,
    ML.매출일자,
    P.상품명
FROM 고객별최신매출 ML,
     고객기본정보 C,
     상품정보 P,
     지역정보 R
WHERE ML.고객코드 = C.고객코드
  AND ML.상품코드 = P.상품코드
  AND C.지역코드 = R.지역코드
  AND EXISTS (
      SELECT 1 FROM 고객별최고매출 MH
      WHERE MH.고객코드 = ML.고객코드
  )  -- 최고매출이 있는 고객만

ORDER BY 고객코드, 구분;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - SELECT절 참조 컬럼만 다르게 하여 동일 테이블을 UNION으로 반복 ACCESS
    - 각각 별도의 MAX() 서브쿼리로 매출데이터 테이블을 2번 추가 SCAN
    - 총 4번의 매출데이터 테이블 ACCESS (메인 2번 + 서브쿼리 2번)
    - 대량 I/O 및 PGA 사용량 증가
 
 2. 해결책:
    - WINDOW 함수(분석 함수) RANK()로 한 번에 순위 계산
    - WITH절 + MATERIALIZE 힌트로 임시 결과 집합 생성
    - 매출데이터 테이블을 1번만 SCAN하여 모든 순위 정보 생성
    - EXISTS로 조건부 JOIN 최적화
 
 3. WINDOW 함수 활용:
    - RANK() OVER (PARTITION BY 고객코드 ORDER BY 매출금액 DESC): 고객별 매출금액 순위
    - RANK() OVER (PARTITION BY 고객코드 ORDER BY 매출일자 DESC): 고객별 최신 매출 순위
    - 한 번의 SCAN으로 여러 기준의 순위를 동시 계산
 
 4. WITH절 MATERIALIZE:
    - /*+ MATERIALIZE */ 힌트로 임시 테이블 생성 효과
    - 동일한 기본 데이터를 여러 번 사용할 때 성능 향상
    - 복잡한 조건의 중간 결과를 재사용
 
 5. 적용 조건:
    - 동일 테이블을 여러 번 ACCESS하는 UNION 구조
    - GROUP BY나 분석 함수로 해결 가능한 MAX/MIN 서브쿼리
    - 중간 결과를 여러 번 재사용하는 복잡한 쿼리
 
 6. 성과:
    - 매출데이터 테이블 ACCESS: 4회 → 1회 (75% 감소)
    - I/O 대폭 감소 (9,569K → 2,019K, 78.9% 개선)
    - PGA 사용량 최적화
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증
PROMPT ========================================

-- WINDOW 함수 동작 확인 (샘플 데이터)
SELECT 
    고객코드,
    매출금액,
    매출일자,
    RANK() OVER (PARTITION BY 고객코드 ORDER BY 매출금액 DESC) AS 매출금액_순위,
    RANK() OVER (PARTITION BY 고객코드 ORDER BY 매출일자 DESC) AS 매출일자_순위
FROM 매출데이터
WHERE 고객코드 IN ('CUST000001', 'CUST000002', 'CUST000003')
  AND 매출상태 = 'NORMAL'
  AND 매출일자 BETWEEN TO_DATE('20240301', 'YYYYMMDD') AND TO_DATE('20240331', 'YYYYMMDD')
ORDER BY 고객코드, 매출금액 DESC;

-- 고객등급별 분포 확인
SELECT 고객등급, COUNT(*) 건수
FROM 고객기본정보
GROUP BY 고객등급
ORDER BY 고객등급;

-- 매출 기간 내 데이터 건수 확인
SELECT COUNT(*) AS 기간내매출건수
FROM 매출데이터
WHERE 매출일자 BETWEEN TO_DATE('20240301', 'YYYYMMDD') AND TO_DATE('20240331', 'YYYYMMDD')
  AND 매출상태 = 'NORMAL';

-- 권역별 고객 분포 확인  
SELECT R.권역명, COUNT(*) 고객수
FROM 고객기본정보 C, 지역정보 R
WHERE C.지역코드 = R.지역코드
GROUP BY R.권역명
ORDER BY 2 DESC;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 10 WINDOW 함수 + EXISTS 실습 완료 ***