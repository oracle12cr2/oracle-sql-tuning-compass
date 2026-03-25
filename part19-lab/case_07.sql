-- =============================================================================
-- Case 07: 실행 계획 분리 (OPTIONAL 바인드 변수 대응)
-- 핵심 튜닝 기법: UNION ALL로 실행 계획 분리하여 INDEX 효율성 확보
-- 관련 단원: 실행 계획 분리
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 경영체등록내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 경영체종사원등록내역 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 데이터 생성
PROMPT ========================================

-- 경영체등록내역 테이블 생성
CREATE TABLE 경영체등록내역 AS
SELECT 
    'FARM' || LPAD(rownum, 10, '0') AS 경영체등록번호,
    'R' || LPAD(MOD(rownum-1, 50000) + 1, 13, '0') AS 경영주실명번호,
    '농장주' || rownum AS 경영주명,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 1800)), 'YYYYMMDD') AS 등록일자,
    CASE MOD(rownum, 5) WHEN 0 THEN '1' ELSE '0' END AS 삭제여부,  -- 삭제 20%
    CASE MOD(rownum, 3) 
        WHEN 0 THEN '개인'
        WHEN 1 THEN '법인'
        ELSE '단체'
    END AS 경영체유형
FROM dual 
CONNECT BY level <= 200000;

-- 경영체종사원등록내역 테이블 생성
CREATE TABLE 경영체종사원등록내역 AS
SELECT 
    'FARM' || LPAD(MOD(rownum-1, 200000) + 1, 10, '0') AS 경영체등록번호,
    rownum AS 종사원순번,
    'EMP' || LPAD(rownum, 10, '0') AS 종사원번호,
    '종사원' || rownum AS 종사원명,
    CASE MOD(rownum, 8) WHEN 0 THEN '1' ELSE '0' END AS 삭제여부,  -- 삭제 12.5%
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)), 'YYYYMMDD') AS 등록일자
FROM dual
CONNECT BY level <= 800000;

-- PK 및 INDEX 생성
ALTER TABLE 경영체등록내역 ADD CONSTRAINT PK_경영체등록내역 PRIMARY KEY (경영체등록번호);
ALTER TABLE 경영체종사원등록내역 ADD CONSTRAINT PK_경영체종사원등록내역 PRIMARY KEY (경영체등록번호, 종사원순번);

-- 필요한 INDEX 생성 (OPTIONAL 조건을 위한 INDEX)
CREATE INDEX IDX_경영체등록내역_01 ON 경영체등록내역 (삭제여부, 경영체등록번호);  -- 경영체등록번호 조건용
CREATE INDEX IDX_경영체등록내역_02 ON 경영체등록내역 (삭제여부, 경영주실명번호);  -- 경영주실명번호 조건용
CREATE INDEX IDX_경영체종사원등록내역_01 ON 경영체종사원등록내역 (삭제여부, 경영체등록번호);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '경영체등록내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '경영체종사원등록내역');

-- 테이블 크기 및 삭제여부 분포 확인
SELECT table_name 테이블명, num_rows 건수 FROM user_tables 
WHERE table_name IN ('경영체등록내역', '경영체종사원등록내역');

SELECT '경영체등록내역' 테이블, 삭제여부, COUNT(*) 건수
FROM 경영체등록내역 GROUP BY 삭제여부
UNION ALL
SELECT '경영체종사원등록내역' 테이블, 삭제여부, COUNT(*) 건수
FROM 경영체종사원등록내역 GROUP BY 삭제여부;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획 (OPTIONAL 바인드)
PROMPT ========================================

-- 바인드 변수 설정 (OPTIONAL - NULL 가능)
VARIABLE B1 VARCHAR2(20);  -- 경영주실명번호1
VARIABLE B2 VARCHAR2(20);  -- 경영주실명번호2  
VARIABLE B3 VARCHAR2(20);  -- 경영주명
VARIABLE B4 VARCHAR2(20);  -- 경영체등록번호

-- 시나리오 1: 경영체등록번호로 조회
EXEC :B1 := NULL;
EXEC :B2 := NULL; 
EXEC :B3 := NULL;
EXEC :B4 := 'FARM0000001000';

-- 튜닝 전 SQL (DECODE/NVL 사용으로 INDEX 비효율)
SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명
FROM 경영체등록내역 A,
     경영체종사원등록내역 B  
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND A.경영체등록번호 = NVL(:B4, A.경영체등록번호)  -- OPTIONAL 조건
  AND A.경영주실명번호 = DECODE(:B1, NULL, A.경영주실명번호, :B1)  -- OPTIONAL 조건
  AND A.경영주실명번호 = DECODE(:B2, NULL, A.경영주실명번호, :B2)  -- OPTIONAL 조건  
  AND A.경영주명 LIKE DECODE(:B3, NULL, '%', '%' || :B3 || '%');  -- OPTIONAL 조건

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획 (실행 계획 분리)
PROMPT ========================================

-- 튜닝 후 SQL (UNION ALL로 실행 계획 분리)
SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NOT NULL 
  AND A.경영체등록번호 = :B4

UNION ALL

SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NULL
  AND (:B1 IS NOT NULL OR :B2 IS NOT NULL)
  AND A.경영주실명번호 IN (:B1, :B2);

PROMPT
PROMPT ========================================
PROMPT 4. 시나리오별 테스트
PROMPT ========================================

-- 시나리오 2: 경영주실명번호로 조회
EXEC :B1 := 'R0000000010000';
EXEC :B2 := NULL; 
EXEC :B3 := NULL;
EXEC :B4 := NULL;

PROMPT
PROMPT "=== 경영주실명번호 조회 시나리오 ==="

-- 실행 계획 분리된 SQL로 재실행
SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NOT NULL 
  AND A.경영체등록번호 = :B4

UNION ALL

SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NULL
  AND (:B1 IS NOT NULL OR :B2 IS NOT NULL)
  AND A.경영주실명번호 IN (:B1, :B2);

PROMPT
PROMPT ========================================
PROMPT 5. 추가 최적화 - 더 세분화된 분리
PROMPT ========================================

-- 시나리오 3: 모든 조건을 세분화
EXEC :B1 := NULL;
EXEC :B2 := NULL; 
EXEC :B3 := '농장주1';
EXEC :B4 := NULL;

-- 완전한 실행 계획 분리 (각 조건별로 최적 INDEX 사용)
SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명,
    '경영체등록번호조회' AS 조회구분
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NOT NULL 
  AND A.경영체등록번호 = :B4

UNION ALL

SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명,
    '실명번호조회' AS 조회구분
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NULL
  AND (:B1 IS NOT NULL OR :B2 IS NOT NULL)
  AND A.경영주실명번호 IN (:B1, :B2)

UNION ALL

SELECT 
    A.경영체등록번호, A.경영주실명번호, A.경영주명,
    A.등록일자, B.종사원번호, B.종사원명,
    '경영주명조회' AS 조회구분
FROM 경영체등록내역 A,
     경영체종사원등록내역 B
WHERE A.삭제여부 = '0' 
  AND B.삭제여부 = '0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND :B4 IS NULL
  AND :B1 IS NULL 
  AND :B2 IS NULL
  AND :B3 IS NOT NULL
  AND A.경영주명 LIKE '%' || :B3 || '%';

PROMPT
PROMPT ========================================
PROMPT 6. 성능 분석 및 튜닝 포인트
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - OPTIONAL 바인드 변수: 값이 있을 수도 없을 수도 있음
    - DECODE, NVL 함수 사용으로 INDEX 사용 불가
    - 옵티마이저가 최적의 실행계획 선택 불가
    - 모든 경우를 고려한 일반적 계획으로 FULL TABLE SCAN 발생
 
 2. OPTIONAL 바인드 변수 문제:
    - 실행 시점에 조건이 결정됨
    - 컴파일 시점에 최적 INDEX 선택 불가
    - 함수 사용으로 INDEX 조건 활용 불가
 
 3. 실행 계획 분리 원리:
    - 각 시나리오별로 별도의 실행계획 생성
    - 조건에 따라 최적의 INDEX 사용 가능
    - UNION ALL로 결합하여 동일 결과 보장
 
 4. 분리 조건 설계:
    - 상호배타적 조건으로 분리 (AND 연산자)
    - NULL 체크를 이용한 조건 분기
    - 각 분기별 최적 INDEX 존재 확인
 
 5. 튜닝 방법:
    - 주요 조회 패턴별로 UNION ALL 분기 생성
    - IS NULL, IS NOT NULL로 조건 분리
    - 각 분기에 적절한 힌트 적용
 
 6. 주의 사항:
    - UNION ALL 분기가 너무 많으면 관리 복잡
    - 중복 데이터 방지 위한 상호배타적 조건 필수
    - 실행 계획 확인 필수 (원하는 INDEX 사용 여부)
 
 7. 적용 효과:
    - FULL TABLE SCAN → INDEX RANGE SCAN
    - 조회 패턴별 최적 성능
    - 애플리케이션 수정 최소화
*/

PROMPT
PROMPT ========================================
PROMPT 7. INDEX 사용 현황 분석
PROMPT ========================================

-- 각 시나리오별 INDEX 선택도 확인
SELECT 'IDX_경영체등록내역_01 (경영체등록번호)' INDEX명,
       COUNT(*) 전체건수,
       COUNT(CASE WHEN 삭제여부='0' THEN 1 END) 유효건수,
       ROUND(COUNT(CASE WHEN 삭제여부='0' THEN 1 END) / COUNT(*) * 100, 2) AS 선택도
FROM 경영체등록내역
UNION ALL
SELECT 'IDX_경영체등록내역_02 (경영주실명번호)',
       COUNT(*),
       COUNT(CASE WHEN 삭제여부='0' THEN 1 END),
       ROUND(COUNT(CASE WHEN 삭제여부='0' THEN 1 END) / COUNT(*) * 100, 2)
FROM 경영체등록내역;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 07 실행 계획 분리 실습 완료 ***
PROMPT *** 바인드 변수 시나리오별로 다른 INDEX 사용 확인하세요! ***