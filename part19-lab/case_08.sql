-- =============================================================================
-- Case 08: JOIN 순서 변경 + 스칼라 서브쿼리
-- 핵심 튜닝 기법: JOIN 순서 최적화 및 스칼라 서브쿼리 캐싱 활용
-- 관련 단원: JOIN, 실행 계획 분리
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 취급상품기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 상품기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 취급상품매출단가 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 상품기본 테이블 생성 (DBA_OBJECTS 기반)
CREATE TABLE 상품기본 AS
SELECT 
    object_id AS 상품코드,
    CASE 
        WHEN MOD(object_id, 100) < 5 THEN '고추'
        WHEN MOD(object_id, 100) < 10 THEN '무'
        WHEN MOD(object_id, 100) < 15 THEN '배추'
        WHEN MOD(object_id, 100) < 20 THEN '양파'
        ELSE SUBSTR(object_name, 1, 10)
    END AS 상품명,
    object_type AS 상품분류,
    owner AS 제조업체,
    created AS 등록일자,
    'Y' AS 사용여부
FROM dba_objects
WHERE rownum <= 50000;

-- 취급상품기본 테이블 생성
CREATE TABLE 취급상품기본 AS
SELECT 
    rownum AS 취급상품ID,
    '8808990167909' AS 사업장코드,
    상품코드,
    상품명,
    ROUND(DBMS_RANDOM.VALUE(100, 5000), 0) AS 기본매출단가,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 취급시작일,
    'Y' AS 취급여부,
    created AS 등록일시
FROM 상품기본
WHERE rownum <= 36000;  -- 36K건

-- 취급상품매출단가 테이블 생성
CREATE TABLE 취급상품매출단가 AS
SELECT 
    rownum AS 단가ID,
    취급상품ID,
    사업장코드,
    상품코드,
    '01' AS 매출단가유형코드,
    기본매출단가 + ROUND(DBMS_RANDOM.VALUE(-500, 1000), 0) AS 매출단가,
    취급시작일 AS 단가적용시작일,
    취급시작일 + 30 AS 단가적용종료일,
    'Y' AS 적용여부
FROM 취급상품기본
WHERE MOD(rownum, 20) = 1;  -- 약 1,800건

-- PK 및 INDEX 생성
ALTER TABLE 상품기본 ADD CONSTRAINT PK_상품기본 PRIMARY KEY (상품코드);
ALTER TABLE 취급상품기본 ADD CONSTRAINT PK_취급상품기본 PRIMARY KEY (취급상품ID);
ALTER TABLE 취급상품매출단가 ADD CONSTRAINT PK_취급상품매출단가 PRIMARY KEY (단가ID);

-- 핵심 INDEX: 상품명으로 검색하는 INDEX
CREATE INDEX 상품기본_IX1 ON 상품기본 (상품명, 상품코드);
CREATE INDEX 취급상품기본_IX1 ON 취급상품기본 (사업장코드, 상품코드);
CREATE INDEX 취급상품매출단가_IX1 ON 취급상품매출단가 (취급상품ID, 매출단가유형코드);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '상품기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '취급상품기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '취급상품매출단가');

-- 데이터 분포 확인
SELECT '상품기본' 테이블명, COUNT(*) 건수 FROM 상품기본
UNION ALL
SELECT '취급상품기본', COUNT(*) FROM 취급상품기본
UNION ALL
SELECT '취급상품매출단가', COUNT(*) FROM 취급상품매출단가;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 사업장코드 VARCHAR2(20);
VARIABLE 상품코드 VARCHAR2(20);
VARIABLE 상품명 VARCHAR2(50);
VARIABLE 매출단가유형코드 VARCHAR2(10);

EXEC :사업장코드 := '8808990167909';
EXEC :상품코드 := NULL;
EXEC :상품명 := '고추';
EXEC :매출단가유형코드 := '01';

-- 튜닝 전 SQL (JOIN 순서 비효율)
SELECT 
    A.취급상품ID,
    A.상품코드,
    B.상품명,
    A.기본매출단가,
    C.매출단가,
    A.취급시작일
FROM 취급상품기본 A,
     상품기본 B,
     취급상품매출단가 C
WHERE A.사업장코드 = :사업장코드
  AND A.상품코드 = NVL(:상품코드, A.상품코드)
  AND A.상품코드 = B.상품코드
  AND B.상품명 LIKE ('%' || :상품명 || '%')
  AND B.사용여부 = 'Y'
  AND A.취급여부 = 'Y'
  AND A.취급상품ID = C.취급상품ID(+)
  AND C.매출단가유형코드(+) = :매출단가유형코드
  AND C.적용여부(+) = 'Y'
ORDER BY B.상품명, A.상품코드;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (JOIN 순서 최적화 + 스칼라 서브쿼리)
SELECT /*+ LEADING(B A) USE_NL(B A) */
    A.취급상품ID,
    A.상품코드,
    B.상품명,
    A.기본매출단가,
    (SELECT C.매출단가 
     FROM 취급상품매출단가 C
     WHERE A.취급상품ID = C.취급상품ID
       AND C.매출단가유형코드 = :매출단가유형코드
       AND C.적용여부 = 'Y'
       AND ROWNUM = 1) AS 매출단가,
    A.취급시작일
FROM 상품기본 B,
     취급상품기본 A
WHERE B.상품명 LIKE ('%' || :상품명 || '%')
  AND B.사용여부 = 'Y'
  AND A.사업장코드 = :사업장코드
  AND A.상품코드 = NVL(:상품코드, A.상품코드)
  AND A.상품코드 = B.상품코드
  AND A.취급여부 = 'Y'
ORDER BY B.상품명, A.상품코드;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 선행 테이블(취급상품기본) 36,000건이 후행과 NL JOIN
    - 상품명 LIKE 조건에 의해 최종적으로 소수만 남음 → 대부분 필터링
    - 비효율적인 JOIN 순서로 불필요한 I/O 발생
 
 2. 해결책:
    - JOIN 순서 변경: 상품기본(필터링) → 취급상품기본(매칭)
    - LEADING 힌트로 상품기본을 선행 테이블로 지정
    - 취급상품매출단가와의 LEFT OUTER JOIN을 스칼라 서브쿼리로 변경
    - 스칼라 서브쿼리 캐싱 효과 활용 (동일 매출단가유형코드)
 
 3. 적용 조건:
    - 선행 테이블에서 필터링 효과가 높은 조건이 있을 때
    - OUTER JOIN 대상의 값 종류가 적을 때 (스칼라 서브쿼리 캐싱)
    - NL JOIN이 적절한 상황에서 JOIN 순서만 조정
 
 4. 성과:
    - 필터링을 먼저 수행하여 JOIN 대상 건수 대폭 축소
    - 스칼라 서브쿼리 캐싱으로 반복 ACCESS 최소화
    - I/O 대폭 감소 예상
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증
PROMPT ========================================

-- 상품명별 분포 확인
SELECT 상품명, COUNT(*) 건수
FROM 상품기본
WHERE 상품명 LIKE '%고추%' OR 상품명 LIKE '%무%' OR 상품명 LIKE '%배추%'
GROUP BY 상품명
ORDER BY 2 DESC;

-- 매출단가유형코드별 분포 확인
SELECT 매출단가유형코드, COUNT(*) 건수
FROM 취급상품매출단가
GROUP BY 매출단가유형코드
ORDER BY 1;

-- JOIN 후 예상 결과 건수 확인
SELECT COUNT(*) AS 예상결과건수
FROM 상품기본 B,
     취급상품기본 A
WHERE B.상품명 LIKE '%고추%'
  AND B.사용여부 = 'Y'
  AND A.사업장코드 = '8808990167909'
  AND A.상품코드 = B.상품코드
  AND A.취급여부 = 'Y';

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 08 JOIN 순서 변경 + 스칼라 서브쿼리 실습 완료 ***