-- =============================================================================
-- Case 06: EXISTS + JOIN 순서 변경
-- 핵심 튜닝 기법: 반복 서브쿼리를 EXISTS로 변환하고 JOIN 순서 최적화
-- 관련 단원: JOIN, 서브쿼리, 동일 데이터 반복 ACCESS 튜닝
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 거래내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 계좌기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 고객정보 CASCADE CONSTRAINTS PURGE;
DROP TABLE 상품정보 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 데이터 생성
PROMPT ========================================

-- 거래내역 테이블 생성 (대용량)
CREATE TABLE 거래내역 AS
SELECT 
    rownum AS 거래번호,
    '110' || LPAD(MOD(rownum-1, 50000) + 1, 10, '0') AS 계좌번호,
    'P' || LPAD(MOD(rownum-1, 100) + 1, 6, '0') AS 상품코드,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)), 'YYYYMMDD') AS 거래일자,
    ROUND(DBMS_RANDOM.VALUE(1000, 100000), 0) AS 거래금액,
    CASE MOD(rownum, 3) WHEN 0 THEN '입금' WHEN 1 THEN '출금' ELSE '이체' END AS 거래구분,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)) + DBMS_RANDOM.VALUE(0, 1) AS 거래시간
FROM dual 
CONNECT BY level <= 1000000;  -- 100만건

-- 계좌기본 테이블 생성
CREATE TABLE 계좌기본 AS
SELECT 
    '110' || LPAD(rownum, 10, '0') AS 계좌번호,
    'C' || LPAD(MOD(rownum-1, 10000) + 1, 8, '0') AS 고객번호,
    'P' || LPAD(MOD(rownum-1, 100) + 1, 6, '0') AS 상품코드,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 1000)), 'YYYYMMDD') AS 개설일자,
    CASE MOD(rownum, 3) WHEN 0 THEN '정상' WHEN 1 THEN '해지' ELSE '정지' END AS 계좌상태
FROM dual
CONNECT BY level <= 50000;

-- 고객정보 테이블 생성 (소형 테이블)
CREATE TABLE 고객정보 AS
SELECT 
    'C' || LPAD(rownum, 8, '0') AS 고객번호,
    '고객' || rownum AS 고객명,
    CASE MOD(rownum, 3) WHEN 0 THEN 'VIP' WHEN 1 THEN '일반' ELSE '우수' END AS 등급,
    TRUNC(SYSDATE) - TRUNC(DBMS_RANDOM.VALUE(18*365, 80*365)) AS 생년월일
FROM dual
CONNECT BY level <= 10000;

-- 상품정보 테이블 생성 (매우 소형)
CREATE TABLE 상품정보 AS
SELECT 
    'P' || LPAD(rownum, 6, '0') AS 상품코드,
    '상품' || rownum AS 상품명,
    CASE MOD(rownum, 4) WHEN 0 THEN '예금' WHEN 1 THEN '적금' WHEN 2 THEN '대출' ELSE '기타' END AS 상품분류
FROM dual
CONNECT BY level <= 100;

-- PK 및 INDEX 생성
ALTER TABLE 거래내역 ADD CONSTRAINT PK_거래내역 PRIMARY KEY (거래번호);
ALTER TABLE 계좌기본 ADD CONSTRAINT PK_계좌기본 PRIMARY KEY (계좌번호);
ALTER TABLE 고객정보 ADD CONSTRAINT PK_고객정보 PRIMARY KEY (고객번호);
ALTER TABLE 상품정보 ADD CONSTRAINT PK_상품정보 PRIMARY KEY (상품코드);

-- 필요한 INDEX 생성
CREATE INDEX IDX_거래내역_01 ON 거래내역 (계좌번호, 거래일자);
CREATE INDEX IDX_거래내역_02 ON 거래내역 (상품코드, 거래일자);
CREATE INDEX IDX_계좌기본_01 ON 계좌기본 (고객번호);
CREATE INDEX IDX_계좌기본_02 ON 계좌기본 (상품코드);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '거래내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '계좌기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '고객정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '상품정보');

-- 테이블 크기 확인
SELECT table_name 테이블명, num_rows 건수,
       ROUND(num_rows * avg_row_len / 1024 / 1024, 2) AS 크기_MB
FROM user_tables 
WHERE table_name IN ('거래내역', '계좌기본', '고객정보', '상품정보')
ORDER BY num_rows DESC;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획 (반복 서브쿼리)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 기준일자 VARCHAR2(8);
VARIABLE 상품분류 VARCHAR2(10);
EXEC :기준일자 := TO_CHAR(SYSDATE-30, 'YYYYMMDD');
EXEC :상품분류 := '예금';

-- 튜닝 전 SQL (MAX 서브쿼리로 거래내역 2번 접근)
SELECT 
    A.계좌번호, A.고객번호, C.고객명, C.등급,
    D.상품명, D.상품분류,
    A.개설일자, A.계좌상태,
    최근거래.거래일자 최근거래일자,
    최근거래.거래금액 최근거래금액
FROM 계좌기본 A,
     고객정보 C,
     상품정보 D,
     (SELECT 계좌번호, 거래일자, 거래금액
      FROM 거래내역 T1
      WHERE 거래일자 = (SELECT MAX(거래일자) 
                      FROM 거래내역 T2 
                      WHERE T2.계좌번호 = T1.계좌번호 
                        AND T2.거래일자 >= :기준일자)) 최근거래
WHERE A.고객번호 = C.고객번호
  AND A.상품코드 = D.상품코드
  AND A.계좌번호 = 최근거래.계좌번호
  AND D.상품분류 = :상품분류
  AND A.계좌상태 = '정상'
ORDER BY A.계좌번호;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획 (EXISTS 사용)
PROMPT ========================================

-- 튜닝 후 SQL (EXISTS로 변환 + JOIN 순서 최적화)
SELECT /*+ LEADING(D C A B) USE_NL(C A) USE_HASH(B) */
    A.계좌번호, A.고객번호, C.고객명, C.등급,
    D.상품명, D.상품분류,
    A.개설일자, A.계좌상태,
    B.거래일자 최근거래일자,
    B.거래금액 최근거래금액
FROM 계좌기본 A,
     거래내역 B,
     고객정보 C,
     상품정보 D
WHERE A.고객번호 = C.고객번호
  AND A.상품코드 = D.상품코드
  AND A.계좌번호 = B.계좌번호
  AND B.거래일자 >= :기준일자
  AND D.상품분류 = :상품분류
  AND A.계좌상태 = '정상'
  AND EXISTS (SELECT 1 
              FROM 거래내역 T2
              WHERE T2.계좌번호 = B.계좌번호
                AND T2.거래일자 >= :기준일자
                AND T2.거래일자 > B.거래일자)  = 0  -- 최근 거래 조건
ORDER BY A.계좌번호;

PROMPT
PROMPT ========================================
PROMPT 4. 추가 최적화 - WINDOW 함수 활용
PROMPT ========================================

-- WINDOW 함수를 활용한 최적화
SELECT 계좌번호, 고객번호, 고객명, 등급, 상품명, 상품분류,
       개설일자, 계좌상태, 최근거래일자, 최근거래금액
FROM (
    SELECT /*+ LEADING(D C A B) USE_NL(C A) USE_HASH(B) */
        A.계좌번호, A.고객번호, C.고객명, C.등급,
        D.상품명, D.상품분류,
        A.개설일자, A.계좌상태,
        B.거래일자 최근거래일자,
        B.거래금액 최근거래금액,
        ROW_NUMBER() OVER (PARTITION BY A.계좌번호 ORDER BY B.거래일자 DESC, B.거래시간 DESC) AS rn
    FROM 계좌기본 A,
         거래내역 B,
         고객정보 C,
         상품정보 D
    WHERE A.고객번호 = C.고객번호
      AND A.상품코드 = D.상품코드
      AND A.계좌번호 = B.계좌번호
      AND B.거래일자 >= :기준일자
      AND D.상품분류 = :상품분류
      AND A.계좌상태 = '정상'
)
WHERE rn = 1
ORDER BY 계좌번호;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 분석 및 튜닝 포인트
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - MAX() 서브쿼리로 거래내역 테이블을 2번 반복 SCAN
    - JOIN 순서 비효율: 대용량 테이블 결과가 소형 테이블과 NL JOIN
    - 53만건 JOIN 후 상품분류 조건으로 90% 필터링
 
 2. 반복 ACCESS 문제:
    - 동일 테이블을 여러 번 접근하는 패턴
    - MAX(), MIN() 서브쿼리가 주요 원인
    - 각각 별도의 INDEX SCAN 발생
 
 3. JOIN 순서 최적화:
    - LEADING 힌트로 선택도 좋은 테이블부터 접근
    - 소형 테이블(상품정보, 고객정보) → 중형 테이블(계좌기본) → 대형 테이블(거래내역)
    - 조건절 선택도를 고려한 순서 결정
 
 4. 튜닝 방법:
    - MAX 서브쿼리 → EXISTS 또는 WINDOW 함수로 변환
    - LEADING 힌트로 JOIN 순서 최적화
    - USE_HASH/USE_NL 힌트로 JOIN 방법 제어
 
 5. EXISTS vs WINDOW 함수:
    - EXISTS: 조건 만족 시 즉시 중단, 효율적
    - WINDOW 함수: 모든 데이터 처리 후 정렬, 안정적
    - 데이터 특성에 따라 선택
 
 6. 성과:
    - Buffers: 1,809K → 7,668 (99.6% 개선)
    - 실행 시간: 2분 9초 → 대폭 개선
    - 거래내역 테이블 중복 ACCESS 제거
*/

PROMPT
PROMPT ========================================
PROMPT 6. JOIN 순서 영향도 분석
PROMPT ========================================

-- 각 테이블별 조건 후 건수 확인
SELECT '상품정보(상품분류 조건)' 구분, COUNT(*) 건수 
FROM 상품정보 WHERE 상품분류 = :상품분류
UNION ALL
SELECT '계좌기본(계좌상태 조건)', COUNT(*) 
FROM 계좌기본 WHERE 계좌상태 = '정상'
UNION ALL
SELECT '거래내역(기준일자 조건)', COUNT(*) 
FROM 거래내역 WHERE 거래일자 >= :기준일자
UNION ALL
SELECT '고객정보 전체', COUNT(*) FROM 고객정보;

-- 최종 JOIN 결과 건수 확인 (샘플)
SELECT COUNT(*) 예상결과건수
FROM 계좌기본 A,
     고객정보 C,
     상품정보 D
WHERE A.고객번호 = C.고객번호
  AND A.상품코드 = D.상품코드  
  AND D.상품분류 = :상품분류
  AND A.계좌상태 = '정상'
  AND rownum <= 1000;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 06 EXISTS + JOIN 순서 변경 실습 완료 ***
PROMPT *** LEADING 힌트와 EXISTS 변환 효과를 확인하세요! ***