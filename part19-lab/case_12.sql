-- =============================================================================
-- Case 12: INDEX FULL SCAN(MIN/MAX) 유도
-- 핵심 튜닝 기법: TOP N 쿼리로 MIN/MAX 최적화 및 페이징 처리
-- 관련 단원: INDEX ACCESS 패턴, 페이징 처리
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 일자관리 CASCADE CONSTRAINTS PURGE;
DROP TABLE 휴일관리 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 일자관리 테이블 생성 (DBA_OBJECTS 기반)
CREATE TABLE 일자관리 AS
SELECT 
    TO_DATE('2020-01-01', 'YYYY-MM-DD') + (rownum - 1) AS 제로인기준일자,
    TO_CHAR(TO_DATE('2020-01-01', 'YYYY-MM-DD') + (rownum - 1), 'D') AS 제로인요일구분,  -- 1:일요일 ~ 7:토요일
    CASE 
        WHEN TO_CHAR(TO_DATE('2020-01-01', 'YYYY-MM-DD') + (rownum - 1), 'D') IN ('1', '7') 
        THEN '1'  -- 주말
        WHEN MOD(rownum, 20) = 0 
        THEN '1'  -- 간헐적 휴일
        ELSE '0'  -- 평일
    END AS 제로인휴일구분,
    TO_DATE('2020-01-01', 'YYYY-MM-DD') + (rownum - 1) + 1 AS 제로인익영업일,
    'KOR' AS 국가코드,
    CASE 
        WHEN MOD(rownum, 7) = 1 THEN '신정'
        WHEN MOD(rownum, 100) = 1 THEN '설날'  
        WHEN MOD(rownum, 150) = 1 THEN '추석'
        ELSE NULL
    END AS 휴일명
FROM dual
CONNECT BY rownum <= 2000;  -- 2020년부터 약 5년치

-- 휴일관리 테이블 생성
CREATE TABLE 휴일관리 AS
SELECT 
    제로인기준일자,
    휴일명,
    CASE 
        WHEN 휴일명 IS NOT NULL THEN 'Y'
        ELSE 'N'
    END AS 법정휴일여부,
    '2019-12-31' AS 등록일자
FROM 일자관리
WHERE 휴일명 IS NOT NULL;

-- PK 및 INDEX 생성  
ALTER TABLE 일자관리 ADD CONSTRAINT PK_일자관리 PRIMARY KEY (제로인기준일자);
ALTER TABLE 휴일관리 ADD CONSTRAINT PK_휴일관리 PRIMARY KEY (제로인기준일자);

-- 조회용 복합 INDEX 생성
CREATE INDEX 일자관리_IX1 ON 일자관리 (제로인요일구분, 제로인기준일자);
CREATE INDEX 일자관리_IX2 ON 일자관리 (제로인휴일구분, 제로인기준일자);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '일자관리');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '휴일관리');

-- 데이터 분포 확인
SELECT '일자관리' 테이블명, COUNT(*) 건수 FROM 일자관리
UNION ALL
SELECT '휴일관리', COUNT(*) FROM 휴일관리;

-- 요일구분별 분포 확인
SELECT 
    제로인요일구분,
    CASE 제로인요일구분
        WHEN '1' THEN '일요일'
        WHEN '2' THEN '월요일' 
        WHEN '3' THEN '화요일'
        WHEN '4' THEN '수요일'
        WHEN '5' THEN '목요일'
        WHEN '6' THEN '금요일'
        WHEN '7' THEN '토요일'
    END AS 요일명,
    COUNT(*) 건수
FROM 일자관리
GROUP BY 제로인요일구분
ORDER BY 제로인요일구분;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정 (월요일 기준 조회)
VARIABLE B1 VARCHAR2(10);
EXEC :B1 := '20240523';  -- 2024-05-23 (목요일) 

-- 튜닝 전 SQL (복합 조건으로 INDEX FULL SCAN(MIN/MAX) 미발생)
-- 주어진 일자 이전 가장 최근 월요일 찾기
SELECT 
    CASE WHEN 제로인휴일구분 = '0' 
         THEN 제로인기준일자 
         ELSE 제로인익영업일 
    END AS 주첫번째일자
FROM 일자관리
WHERE 제로인기준일자 = (
    SELECT MAX(제로인기준일자)
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인요일구분 = '2'  -- 월요일
);

-- 추가 사례: 특정 조건의 최신/최고값 조회
PROMPT
PROMPT === 추가 사례 1: 휴일이 아닌 가장 최근 일자 ===
SELECT 
    제로인기준일자,
    제로인요일구분,
    제로인휴일구분
FROM 일자관리
WHERE 제로인기준일자 = (
    SELECT MAX(제로인기준일자)
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인휴일구분 = '0'  -- 휴일 아님
);

PROMPT
PROMPT === 추가 사례 2: 금요일 중 가장 최근 일자 ===
SELECT 
    제로인기준일자,
    제로인요일구분,
    제로인휴일구분
FROM 일자관리
WHERE 제로인기준일자 = (
    SELECT MAX(제로인기준일자)
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인요일구분 = '6'  -- 금요일
);

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (TOP N 쿼리로 INDEX FULL SCAN(MIN/MAX) 효과)
-- ROWNUM을 이용한 페이징 방식
SELECT 
    CASE WHEN 제로인휴일구분 = '0' 
         THEN 제로인기준일자 
         ELSE 제로인익영업일 
    END AS 주첫번째일자
FROM (
    SELECT 제로인기준일자, 제로인휴일구분, 제로인익영업일
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인요일구분 = '2'  -- 월요일
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;

PROMPT
PROMPT === 튜닝 후 추가 사례들 ===

-- 휴일이 아닌 가장 최근 일자 (튜닝)
SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
FROM (
    SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인휴일구분 = '0'
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;

-- 금요일 중 가장 최근 일자 (튜닝)
SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
FROM (
    SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인요일구분 = '6'
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;

-- FIRST_VALUE 분석함수를 이용한 방법 (대안)
PROMPT
PROMPT === 분석함수 활용 대안 ===
SELECT DISTINCT
    FIRST_VALUE(제로인기준일자) OVER (ORDER BY 제로인기준일자 DESC) AS 최근월요일
FROM 일자관리
WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
  AND 제로인요일구분 = '2';

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - [제로인기준일자] 컬럼이 PK INDEX이지만 복합 조건 사용
    - [제로인기준일자 <= :B1 AND 제로인요일구분 = '2'] 조건으로 인해
      INDEX FULL SCAN(MIN/MAX) 실행계획이 나타나지 못함
    - 조건에 해당하는 모든 범위를 SCAN 후 MAX값을 찾는 비효율
    - 하루 200,000번 이상 수행되는 빈번한 SQL
 
 2. 해결책:
    - 표준 PAGINATION의 TOP N 쿼리 방식 적용
    - PK INDEX를 역순으로 SCAN 후 ROWNUM <= 1로 첫 번째만 선택
    - 기준일자가 가장 큰 경우만 SCAN하고 즉시 중단
    - INDEX FULL SCAN(MIN/MAX) 효과 달성
 
 3. TOP N 쿼리 패턴:
    - ORDER BY 정렬컬럼 DESC + ROWNUM <= N
    - INDEX를 역순으로 스캔하여 조건에 맞는 최초 N건만 반환
    - 전체를 SCAN하지 않고 조건 만족 시 즉시 중단
    - MIN의 경우 ORDER BY 정렬컬럼 ASC 사용
 
 4. INDEX FULL SCAN(MIN/MAX) 조건:
    - 단일 컬럼에 대한 MAX/MIN 함수
    - WHERE 조건이 INDEX 컬럼과 완전히 일치하거나 없어야 함
    - 복합 조건이나 함수 적용 시 일반 INDEX SCAN으로 변경됨
 
 5. 적용 시나리오:
    - 날짜/시간 기반의 최신/최고값 조회
    - 순번이나 ID 기반의 최대/최소값 조회  
    - 페이징 처리가 필요한 정렬 조회
    - 빈번하게 수행되는 단건 조회
 
 6. 성과:
    - I/O 대폭 감소 (조건 범위 전체 SCAN → 첫 번째 조건 만족 시 중단)
    - 빈번한 수행으로 인한 누적 성능 향상 효과 극대화
    - INDEX RANGE SCAN → INDEX FULL SCAN(MIN/MAX) 효과
    - 실행 시간 단축 및 CPU 사용률 감소
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증 및 활용 예시
PROMPT ========================================

-- MIN/MAX 최적화 비교 테스트
PROMPT
PROMPT === MAX() vs TOP N 쿼리 비교 ===

-- 전통적인 MAX() 방식
SELECT MAX(제로인기준일자) AS 최대일자_MAX방식
FROM 일자관리
WHERE 제로인요일구분 = '2';

-- TOP N 쿼리 방식  
SELECT 제로인기준일자 AS 최대일자_TOPN방식
FROM (
    SELECT 제로인기준일자
    FROM 일자관리
    WHERE 제로인요일구분 = '2'
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;

-- 페이징 활용 예시들
PROMPT
PROMPT === 페이징 활용 예시 ===

-- 가장 최근 5개 월요일 조회
SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
FROM (
    SELECT 제로인기준일자, 제로인요일구분, 제로인휴일구분
    FROM 일자관리
    WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
      AND 제로인요일구분 = '2'
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 5;

-- 특정 범위 내 첫 번째/마지막 휴일
SELECT '첫번째_휴일' AS 구분, 제로인기준일자, 휴일명
FROM (
    SELECT 제로인기준일자, 휴일명
    FROM 일자관리
    WHERE 제로인기준일자 BETWEEN TO_DATE('20240301', 'YYYYMMDD') AND TO_DATE('20240331', 'YYYYMMDD')
      AND 휴일명 IS NOT NULL
    ORDER BY 제로인기준일자 ASC
)
WHERE ROWNUM <= 1

UNION ALL

SELECT '마지막_휴일' AS 구분, 제로인기준일자, 휴일명
FROM (
    SELECT 제로인기준일자, 휴일명
    FROM 일자관리
    WHERE 제로인기준일자 BETWEEN TO_DATE('20240301', 'YYYYMMDD') AND TO_DATE('20240331', 'YYYYMMDD')
      AND 휴일명 IS NOT NULL
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;

-- 각 요일별 최근 일자 조회 (분석함수 활용)
SELECT 
    제로인요일구분,
    CASE 제로인요일구분
        WHEN '1' THEN '일요일'
        WHEN '2' THEN '월요일'
        WHEN '3' THEN '화요일' 
        WHEN '4' THEN '수요일'
        WHEN '5' THEN '목요일'
        WHEN '6' THEN '금요일'
        WHEN '7' THEN '토요일'
    END AS 요일명,
    MAX(제로인기준일자) AS 최근일자
FROM 일자관리
WHERE 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
GROUP BY 제로인요일구분
ORDER BY 제로인요일구분;

-- 월별 마지막 영업일 조회
SELECT 
    TO_CHAR(제로인기준일자, 'YYYY-MM') AS 년월,
    MAX(제로인기준일자) AS 마지막영업일
FROM 일자관리
WHERE 제로인휴일구분 = '0'  -- 영업일만
  AND 제로인요일구분 NOT IN ('1', '7')  -- 주말 제외
  AND 제로인기준일자 <= TO_DATE(:B1, 'YYYYMMDD')
GROUP BY TO_CHAR(제로인기준일자, 'YYYY-MM')
ORDER BY 1 DESC;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 12 INDEX FULL SCAN(MIN/MAX) 유도 실습 완료 ***