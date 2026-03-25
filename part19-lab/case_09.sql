-- =============================================================================
-- Case 09: JPPD로 인라인뷰 침투 
-- 핵심 튜닝 기법: JOIN PREDICATE PUSH DOWN으로 PGA 사용량 최적화
-- 관련 단원: 서브쿼리, PGA 튜닝
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 게시판관리 CASCADE CONSTRAINTS PURGE;
DROP TABLE 게시판 CASCADE CONSTRAINTS PURGE;
DROP TABLE 공통코드 CASCADE CONSTRAINTS PURGE;
DROP TABLE 상담사인사원장 CASCADE CONSTRAINTS PURGE;
DROP TABLE 사용인 CASCADE CONSTRAINTS PURGE;
DROP TABLE GCCOM_임직원정보 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 게시판관리 테이블 생성 (소형 테이블)
CREATE TABLE 게시판관리 AS
SELECT 
    'BOARD' || LPAD(rownum, 3, '0') AS 게시판ID,
    '공지사항' || rownum AS 게시판명,
    'NOTICE_TYPE' AS 분류코드ID,
    'Y' AS 사용여부,
    SYSDATE - rownum AS 생성일시
FROM dual
CONNECT BY rownum <= 50;

-- 게시판 테이블 생성
CREATE TABLE 게시판 AS
SELECT 
    m.게시판ID,
    rownum AS 게시물번호,
    '제목' || rownum AS 제목,
    '내용' || rownum AS 내용,
    CASE MOD(rownum, 3)
        WHEN 0 THEN 'I'  -- 등록
        WHEN 1 THEN 'U'  -- 수정  
        ELSE 'D'         -- 삭제
    END AS 수정구분,
    'USER' || LPAD(MOD(rownum, 1000) + 1, 6, '0') AS 입력자,
    'USER' || LPAD(MOD(rownum, 1000) + 1, 6, '0') AS 수정자,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 수정일시,
    'TYPE' || LPAD(MOD(rownum, 10) + 1, 2, '0') AS 분류상세코드ID
FROM 게시판관리 m,
     (SELECT level FROM dual CONNECT BY level <= 2000)  -- 각 게시판당 2000개씩
WHERE rownum <= 100000;

-- 공통코드 테이블 생성
CREATE TABLE 공통코드 AS
SELECT 
    'NOTICE_TYPE' AS 코드ID,
    '공지유형' AS 코드명,
    'TYPE' || LPAD(rownum, 2, '0') AS 상세코드ID,
    '유형' || rownum AS 상세코드명,
    'Y' AS 사용여부
FROM dual
CONNECT BY rownum <= 20;

-- 상담사인사원장 테이블 생성
CREATE TABLE 상담사인사원장 AS
SELECT 
    'USER' || LPAD(rownum, 6, '0') AS 개인번호,
    '상담사' || rownum AS 상담사이름,
    'OFF' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS 사무소코드,
    CASE MOD(rownum, 5) WHEN 0 THEN 'N' ELSE 'Y' END AS 사용구분
FROM dual
CONNECT BY rownum <= 500;

-- 사용인 테이블 생성  
CREATE TABLE 사용인 AS
SELECT 
    'USER' || LPAD(rownum + 500, 6, '0') AS 사용인채널코드,
    '사용인' || rownum AS 성명,
    'OFF' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS 사무소코드,
    CASE MOD(rownum, 7) WHEN 0 THEN 'N' ELSE 'Y' END AS 사용구분
FROM dual
CONNECT BY rownum <= 300;

-- GCCOM_임직원정보 테이블 생성
CREATE TABLE GCCOM_임직원정보 AS
SELECT 
    'USER' || LPAD(rownum + 800, 6, '0') AS 개인번호,
    'ONLINE' || LPAD(MOD(rownum, 50) + 1, 3, '0') AS 온라인코드,
    '임직원' || rownum AS 성명,
    'OFF' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS 사무소코드
FROM dual
CONNECT BY rownum <= 200;

-- PK 및 INDEX 생성
ALTER TABLE 게시판관리 ADD CONSTRAINT PK_게시판관리 PRIMARY KEY (게시판ID);
ALTER TABLE 게시판 ADD CONSTRAINT PK_게시판 PRIMARY KEY (게시판ID, 게시물번호);
ALTER TABLE 공통코드 ADD CONSTRAINT PK_공통코드 PRIMARY KEY (코드ID, 상세코드ID);

CREATE INDEX 게시판_IX1 ON 게시판 (수정구분);
CREATE INDEX 게시판_IX2 ON 게시판 (입력자);
CREATE INDEX 상담사인사원장_IX1 ON 상담사인사원장 (개인번호, 사용구분);
CREATE INDEX 사용인_IX1 ON 사용인 (사용인채널코드, 사용구분);
CREATE INDEX GCCOM_임직원정보_IX1 ON GCCOM_임직원정보 (개인번호);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '게시판관리');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '게시판');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '공통코드');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '상담사인사원장');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '사용인');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, 'GCCOM_임직원정보');

-- 데이터 분포 확인
SELECT '게시판' 테이블명, COUNT(*) 건수 FROM 게시판
UNION ALL
SELECT '게시판관리', COUNT(*) FROM 게시판관리
UNION ALL
SELECT '공통코드', COUNT(*) FROM 공통코드;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획  
PROMPT ========================================

-- 바인드 변수 설정 (게시판 관리와 게시판 JOIN 결과 = 1건)
VARIABLE 게시판ID VARCHAR2(10);
VARIABLE 게시물번호 NUMBER;

EXEC :게시판ID := 'BOARD001';
EXEC :게시물번호 := 1;

-- 튜닝 전 SQL (UNION으로 인한 SORT 발생, PGA 32M 사용)
SELECT 
    게시판ID, 게시물번호, 제목, 내용,
    수정구분, 수정자, 수정일시, 코드ID,
    코드명, 상세코드ID, 상세코드명,
    TRIM(SUBSTRB(USR_VALUE, 1, 30)) 사용자명,
    SUBSTRB(USR_VALUE, 31) 사무소코드
FROM (
    SELECT 
        A.게시판ID, A.게시물번호, A.제목, A.내용,
        A.수정구분, A.수정자, A.수정일시, B.코드ID,
        B.코드명, B.상세코드ID, B.상세코드명,
        (SELECT RPAD(상담사이름, 30, ' ') || 사무소코드
         FROM 상담사인사원장 B
         WHERE B.사용구분 = 'Y' AND A.입력자 = B.개인번호
        UNION
        SELECT RPAD(성명, 30, ' ') || 사무소코드  
         FROM 사용인 B
         WHERE B.사용구분 = 'Y' AND A.입력자 = B.사용인채널코드
        UNION
        SELECT RPAD(C.성명, 30, ' ') || H.사무소코드
         FROM GCCOM_임직원정보 C LEFT OUTER JOIN GCCOM_임직원정보 H
           ON H.온라인코드 = C.온라인코드
         WHERE A.입력자 = C.개인번호) USR_VALUE
    FROM 게시판 A 
         INNER JOIN 게시판관리 E ON A.게시판ID = E.게시판ID
         LEFT OUTER JOIN 공통코드 B ON A.분류상세코드ID = B.상세코드ID 
                                   AND E.분류코드ID = B.코드ID
    WHERE A.수정구분 <> 'D'
      AND A.게시판ID = :게시판ID
      AND A.게시물번호 = :게시물번호
) A;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (COALESCE 함수로 스칼라 서브쿼리 변경, PGA 0)
SELECT 
    게시판ID, 게시물번호, 제목, 내용,
    수정구분, 수정자, 수정일시, 코드ID,
    코드명, 상세코드ID, 상세코드명,
    TRIM(SUBSTRB(USR_VALUE, 1, 30)) 사용자명,
    (SELECT D.사무소코드 
     FROM GCCOM_임직원정보 D 
     WHERE SUBSTRB(USR_VALUE, 31) = D.사무소코드
       AND ROWNUM = 1) 사무소명
FROM (
    SELECT 
        A.게시판ID, A.게시물번호, A.제목, A.내용,
        A.수정구분, A.수정자, A.수정일시, B.코드ID,
        B.코드명, B.상세코드ID, B.상세코드명,
        COALESCE(
            (SELECT RPAD(상담사이름, 30, ' ') || 사무소코드
             FROM 상담사인사원장 B
             WHERE B.사용구분 = 'Y' AND A.입력자 = B.개인번호),
            (SELECT RPAD(성명, 30, ' ') || 사무소코드
             FROM 사용인 B  
             WHERE B.사용구분 = 'Y' AND A.입력자 = B.사용인채널코드),
            (SELECT RPAD(C.성명, 30, ' ') || H.사무소코드
             FROM GCCOM_임직원정보 C LEFT OUTER JOIN GCCOM_임직원정보 H
               ON H.온라인코드 = C.온라인코드
             WHERE A.입력자 = C.개인번호)
        ) USR_VALUE
    FROM 게시판 A 
         INNER JOIN 게시판관리 E ON A.게시판ID = E.게시판ID
         LEFT OUTER JOIN 공통코드 B ON A.분류상세코드ID = B.상세코드ID 
                                   AND E.분류코드ID = B.코드ID
    WHERE A.수정구분 <> 'D'
      AND A.게시판ID = :게시판ID
      AND A.게시물번호 = :게시물번호
) A;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - [게시판관리], [게시판]의 JOIN 결과가 1건으로 매우 적음
    - 이 결과가 후행 서브쿼리(UNION)로 침투되지 못함 (JPPD 미발생)
    - 인라인뷰가 별도로 실행되어 UNION으로 인한 SORT 발생
    - PGA 32M 사용 (메모리 낭비)
 
 2. 해결책:
    - UNION을 COALESCE 함수로 변경하여 스칼라 서브쿼리 구조로 전환
    - COALESCE(값1, 값2, 값3): NULL이 아닌 최초 값 반환
    - 각 테이블을 개별 스칼라 서브쿼리로 접근
    - SORT 연산 제거로 PGA 사용량 0으로 만듦
 
 3. COALESCE 함수 동작:
    - SELECT COALESCE(NULL, NULL, 'A') FROM DUAL;  => 'A'
    - SELECT COALESCE('B', NULL, 'A') FROM DUAL;   => 'B' 
    - SELECT COALESCE(NULL, 'C', 'A') FROM DUAL;   => 'C'
    - 첫 번째 NOT NULL 값을 반환하고 나머지는 평가하지 않음
 
 4. 적용 조건:
    - UNION으로 동일한 구조의 데이터를 합칠 때
    - 각 UNION 절이 0 또는 1개의 로우만 반환할 때
    - 우선순위가 있는 여러 테이블에서 값을 찾을 때
 
 5. 성과:
    - PGA 사용량: 32M → 0 (100% 개선)
    - SORT 연산 제거
    - 메모리 효율성 대폭 향상
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증
PROMPT ========================================

-- COALESCE 함수 동작 확인
SELECT 
    COALESCE(NULL, NULL, 'DEFAULT') AS test1,
    COALESCE('FIRST', NULL, 'DEFAULT') AS test2,
    COALESCE(NULL, 'SECOND', 'DEFAULT') AS test3
FROM dual;

-- 각 사용자 테이블별 데이터 분포 확인
SELECT '상담사인사원장' 테이블명, COUNT(*) 건수, SUM(CASE WHEN 사용구분='Y' THEN 1 ELSE 0 END) 사용중 FROM 상담사인사원장
UNION ALL
SELECT '사용인', COUNT(*), SUM(CASE WHEN 사용구분='Y' THEN 1 ELSE 0 END) FROM 사용인
UNION ALL  
SELECT 'GCCOM_임직원정보', COUNT(*), COUNT(*) FROM GCCOM_임직원정보;

-- 게시판-게시판관리 JOIN 결과 건수 확인
SELECT COUNT(*) AS JOIN결과건수
FROM 게시판 A 
     INNER JOIN 게시판관리 E ON A.게시판ID = E.게시판ID
WHERE A.수정구분 <> 'D'
  AND A.게시판ID = 'BOARD001'
  AND A.게시물번호 = 1;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 09 JPPD로 인라인뷰 침투 실습 완료 ***