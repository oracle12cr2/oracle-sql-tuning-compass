-- =============================================================================
-- Case 11: UNION → CASE WHEN 통합
-- 핵심 튜닝 기법: 반복 SCAN 제거를 위한 CASE WHEN 활용
-- 관련 단원: 동일 데이터 반복 ACCESS 튜닝
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 계좌거래내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 계좌기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 고객정보 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 고객정보 테이블 생성
CREATE TABLE 고객정보 AS
SELECT 
    'CUST' || LPAD(rownum, 8, '0') AS 고객번호,
    '고객' || rownum AS 고객명,
    CASE MOD(rownum, 4)
        WHEN 0 THEN 'PREMIUM'
        WHEN 1 THEN 'VIP' 
        WHEN 2 THEN 'GOLD'
        ELSE 'NORMAL'
    END AS 고객등급,
    TO_DATE('2020-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 1460)) AS 가입일자
FROM dual
CONNECT BY rownum <= 50000;

-- 계좌기본 테이블 생성  
CREATE TABLE 계좌기본 AS
SELECT 
    '110-' || LPAD(rownum, 10, '0') AS 계좌번호,
    'CUST' || LPAD(MOD(rownum, 50000) + 1, 8, '0') AS 고객번호,
    CASE MOD(rownum, 5)
        WHEN 0 THEN '예금'
        WHEN 1 THEN '적금'  
        WHEN 2 THEN '당좌'
        WHEN 3 THEN '대출'
        ELSE '카드'
    END AS 상품유형,
    ROUND(DBMS_RANDOM.VALUE(100000, 50000000), -3) AS 잔액,
    TO_DATE('2021-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 1095)) AS 개설일자,
    CASE MOD(rownum, 10) WHEN 0 THEN 'N' ELSE 'Y' END AS 활성여부
FROM dual
CONNECT BY rownum <= 150000;

-- 계좌거래내역 테이블 생성 (메인 테이블, 대용량)
CREATE TABLE 계좌거래내역 AS
SELECT 
    rownum AS 거래ID,
    '110-' || LPAD(MOD(rownum, 150000) + 1, 10, '0') AS 계좌번호,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + MOD(rownum, 90) AS 거래일자,
    CASE MOD(rownum, 3)
        WHEN 0 THEN '입금'
        WHEN 1 THEN '출금'  
        ELSE '이체'
    END AS 거래구분,
    ROUND(DBMS_RANDOM.VALUE(1000, 5000000), -2) AS 거래금액,
    CASE MOD(rownum, 20)
        WHEN 0 THEN 'CANCEL'
        ELSE 'NORMAL'
    END AS 거래상태,
    TO_CHAR(SYSDATE - DBMS_RANDOM.VALUE(0, 1), 'HH24MISS') AS 거래시간,
    '지점' || LPAD(MOD(rownum, 100) + 1, 3, '0') AS 거래지점
FROM dual
CONNECT BY rownum <= 3000000;  -- 300만건

-- PK 및 INDEX 생성
ALTER TABLE 고객정보 ADD CONSTRAINT PK_고객정보 PRIMARY KEY (고객번호);
ALTER TABLE 계좌기본 ADD CONSTRAINT PK_계좌기본 PRIMARY KEY (계좌번호);
ALTER TABLE 계좌거래내역 ADD CONSTRAINT PK_계좌거래내역 PRIMARY KEY (거래ID);

-- 조회용 INDEX 생성
CREATE INDEX 계좌거래내역_IX1 ON 계좌거래내역 (거래일자, 계좌번호);
CREATE INDEX 계좌거래내역_IX2 ON 계좌거래내역 (계좌번호, 거래일자, 거래구분);
CREATE INDEX 계좌기본_IX1 ON 계좌기본 (고객번호, 상품유형);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '고객정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '계좌기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '계좌거래내역');

-- 데이터 분포 확인
SELECT '계좌거래내역' 테이블명, COUNT(*) 건수 FROM 계좌거래내역
UNION ALL
SELECT '계좌기본', COUNT(*) FROM 계좌기본  
UNION ALL
SELECT '고객정보', COUNT(*) FROM 고객정보;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 조회일자 VARCHAR2(10);
VARIABLE 고객등급 VARCHAR2(10);

EXEC :조회일자 := '20240315';
EXEC :고객등급 := 'VIP';

-- 튜닝 전 SQL (UNION으로 동일 테이블 반복 SCAN)
-- 입금 거래와 출금 거래를 각각 집계하되 SELECT절 참조 컬럼만 다름
SELECT 
    '입금' AS 거래유형,
    C.고객번호,
    C.고객명,
    C.고객등급,
    A.상품유형,
    COUNT(*) AS 거래건수,
    SUM(T.거래금액) AS 총거래금액,
    AVG(T.거래금액) AS 평균거래금액,
    MAX(T.거래금액) AS 최대거래금액
FROM 계좌거래내역 T,
     계좌기본 A,
     고객정보 C
WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
  AND T.거래상태 = 'NORMAL'
  AND T.거래구분 = '입금'  -- 입금만
  AND T.계좌번호 = A.계좌번호
  AND A.활성여부 = 'Y'
  AND A.고객번호 = C.고객번호
  AND C.고객등급 = :고객등급
GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형

UNION ALL

SELECT 
    '출금' AS 거래유형,
    C.고객번호,
    C.고객명,
    C.고객등급,
    A.상품유형,
    COUNT(*) AS 거래건수,
    SUM(T.거래금액) AS 총거래금액,
    AVG(T.거래금액) AS 평균거래금액,
    MAX(T.거래금액) AS 최대거래금액
FROM 계좌거래내역 T,
     계좌기본 A,
     고객정보 C
WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
  AND T.거래상태 = 'NORMAL'
  AND T.거래구분 = '출금'  -- 출금만
  AND T.계좌번호 = A.계좌번호
  AND A.활성여부 = 'Y'
  AND A.고객번호 = C.고객번호
  AND C.고객등급 = :고객등급
GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형

UNION ALL

SELECT 
    '이체' AS 거래유형,
    C.고객번호,
    C.고객명,
    C.고객등급,
    A.상품유형,
    COUNT(*) AS 거래건수,
    SUM(T.거래금액) AS 총거래금액,
    AVG(T.거래금액) AS 평균거래금액,
    MAX(T.거래금액) AS 최대거래금액
FROM 계좌거래내역 T,
     계좌기본 A,
     고객정보 C
WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
  AND T.거래상태 = 'NORMAL'
  AND T.거래구분 = '이체'  -- 이체만
  AND T.계좌번호 = A.계좌번호
  AND A.활성여부 = 'Y'
  AND A.고객번호 = C.고객번호
  AND C.고객등급 = :고객등급
GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형

ORDER BY 고객번호, 상품유형, 거래유형;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (CASE WHEN으로 한 번만 SCAN)
SELECT 
    거래유형,
    고객번호,
    고객명,
    고객등급,
    상품유형,
    거래건수,
    총거래금액,
    평균거래금액,
    최대거래금액
FROM (
    SELECT 
        '입금' AS 거래유형,
        C.고객번호,
        C.고객명,
        C.고객등급,
        A.상품유형,
        COUNT(CASE WHEN T.거래구분 = '입금' THEN 1 END) AS 거래건수,
        SUM(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 END) AS 총거래금액,
        AVG(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 END) AS 평균거래금액,
        MAX(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 END) AS 최대거래금액
    FROM 계좌거래내역 T,
         계좌기본 A,
         고객정보 C
    WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
      AND T.거래상태 = 'NORMAL'
      AND T.거래구분 IN ('입금', '출금', '이체')
      AND T.계좌번호 = A.계좌번호
      AND A.활성여부 = 'Y'
      AND A.고객번호 = C.고객번호
      AND C.고객등급 = :고객등급
    GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형
    HAVING COUNT(CASE WHEN T.거래구분 = '입금' THEN 1 END) > 0

    UNION ALL

    SELECT 
        '출금' AS 거래유형,
        C.고객번호,
        C.고객명,
        C.고객등급,
        A.상품유형,
        COUNT(CASE WHEN T.거래구분 = '출금' THEN 1 END) AS 거래건수,
        SUM(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 END) AS 총거래금액,
        AVG(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 END) AS 평균거래금액,
        MAX(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 END) AS 최대거래금액
    FROM 계좌거래내역 T,
         계좌기본 A,
         고객정보 C
    WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
      AND T.거래상태 = 'NORMAL'
      AND T.거래구분 IN ('입금', '출금', '이체')
      AND T.계좌번호 = A.계좌번호
      AND A.활성여부 = 'Y'
      AND A.고객번호 = C.고객번호
      AND C.고객등급 = :고객등급
    GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형
    HAVING COUNT(CASE WHEN T.거래구분 = '출금' THEN 1 END) > 0

    UNION ALL

    SELECT 
        '이체' AS 거래유형,
        C.고객번호,
        C.고객명,
        C.고객등급,
        A.상품유형,
        COUNT(CASE WHEN T.거래구분 = '이체' THEN 1 END) AS 거래건수,
        SUM(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 END) AS 총거래금액,
        AVG(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 END) AS 평균거래금액,
        MAX(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 END) AS 최대거래금액
    FROM 계좌거래내역 T,
         계좌기본 A,
         고객정보 C
    WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
      AND T.거래상태 = 'NORMAL'
      AND T.거래구분 IN ('입금', '출금', '이체')
      AND T.계좌번호 = A.계좌번호
      AND A.활성여부 = 'Y'
      AND A.고객번호 = C.고객번호
      AND C.고객등급 = :고객등급
    GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형
    HAVING COUNT(CASE WHEN T.거래구분 = '이체' THEN 1 END) > 0
)
ORDER BY 고객번호, 상품유형, 거래유형;

-- 더 나은 튜닝안: 완전한 CASE WHEN 통합 (가장 이상적)
PROMPT
PROMPT ========================================
PROMPT 3-1. 최적 튜닝안 (완전 CASE WHEN 통합)
PROMPT ========================================

-- 최적 튜닝 SQL (완전히 하나로 통합)
SELECT 
    거래유형,
    고객번호,
    고객명,
    고객등급,
    상품유형,
    거래건수,
    총거래금액,
    ROUND(평균거래금액, 0) AS 평균거래금액,
    최대거래금액
FROM (
    SELECT 
        C.고객번호,
        C.고객명,
        C.고객등급,
        A.상품유형,
        COUNT(CASE WHEN T.거래구분 = '입금' THEN 1 END) AS 입금건수,
        COUNT(CASE WHEN T.거래구분 = '출금' THEN 1 END) AS 출금건수,
        COUNT(CASE WHEN T.거래구분 = '이체' THEN 1 END) AS 이체건수,
        SUM(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 ELSE 0 END) AS 입금총액,
        SUM(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 ELSE 0 END) AS 출금총액,
        SUM(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 ELSE 0 END) AS 이체총액,
        AVG(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 END) AS 입금평균,
        AVG(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 END) AS 출금평균,
        AVG(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 END) AS 이체평균,
        MAX(CASE WHEN T.거래구분 = '입금' THEN T.거래금액 END) AS 입금최대,
        MAX(CASE WHEN T.거래구분 = '출금' THEN T.거래금액 END) AS 출금최대,
        MAX(CASE WHEN T.거래구분 = '이체' THEN T.거래금액 END) AS 이체최대
    FROM 계좌거래내역 T,
         계좌기본 A,
         고객정보 C
    WHERE T.거래일자 = TO_DATE(:조회일자, 'YYYYMMDD')
      AND T.거래상태 = 'NORMAL'
      AND T.거래구분 IN ('입금', '출금', '이체')
      AND T.계좌번호 = A.계좌번호
      AND A.활성여부 = 'Y'
      AND A.고객번호 = C.고객번호
      AND C.고객등급 = :고객등급
    GROUP BY C.고객번호, C.고객명, C.고객등급, A.상품유형
) 
UNPIVOT (
    (거래건수, 총거래금액, 평균거래금액, 최대거래금액) FOR 거래유형 IN (
        (입금건수, 입금총액, 입금평균, 입금최대) AS '입금',
        (출금건수, 출금총액, 출금평균, 출금최대) AS '출금',
        (이체건수, 이체총액, 이체평균, 이체최대) AS '이체'
    )
)
WHERE 거래건수 > 0
ORDER BY 고객번호, 상품유형, 거래유형;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - UNION으로 동일한 기본 테이블 조합을 3번 반복 SCAN
    - WHERE 조건과 JOIN 조건은 동일하고 거래구분만 다름
    - SELECT절 참조 컬럼도 동일 (집계 함수만 사용)
    - 총 3배의 I/O 발생 (계좌거래내역 300만건 × 3회)
 
 2. 해결책:
    - CASE WHEN을 이용한 조건부 집계로 한 번만 SCAN
    - COUNT(CASE WHEN ... THEN 1 END): 조건에 맞는 건수만 카운트
    - SUM(CASE WHEN ... THEN 값 END): 조건에 맞는 값만 합계
    - UNPIVOT을 사용한 완전 통합 (Oracle 11g 이상)
 
 3. CASE WHEN 집계 함수 패턴:
    - COUNT(CASE WHEN 조건 THEN 1 END): 조건부 건수
    - SUM(CASE WHEN 조건 THEN 값 ELSE 0 END): 조건부 합계  
    - AVG(CASE WHEN 조건 THEN 값 END): 조건부 평균 (NULL 제외)
    - MAX/MIN(CASE WHEN 조건 THEN 값 END): 조건부 최대/최소값
 
 4. UNPIVOT 활용:
    - 여러 컬럼을 행으로 전환하여 결과를 정규화
    - 하나의 SQL로 여러 집계 결과를 동시에 생성
    - UNION ALL 보다 효율적이고 가독성 좋음
 
 5. 적용 조건:
    - 동일한 테이블 조합을 여러 조건으로 반복 조회할 때
    - WHERE 조건 중 일부만 다르고 나머지는 동일할 때
    - 집계 함수 위주의 SELECT절일 때
    - 결과를 구분하는 기준이 명확할 때
 
 6. 성과:
    - 테이블 ACCESS 횟수: 3배 → 1배 (66.7% 감소)
    - I/O 대폭 감소 (반복 SCAN 제거)
    - PGA 사용량 감소 (중복 SORT 연산 제거)
    - 실행 시간 대폭 단축
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증
PROMPT ========================================

-- CASE WHEN 집계 함수 동작 확인
SELECT 
    상품유형,
    COUNT(*) AS 전체건수,
    COUNT(CASE WHEN 거래구분 = '입금' THEN 1 END) AS 입금건수,
    COUNT(CASE WHEN 거래구분 = '출금' THEN 1 END) AS 출금건수,
    COUNT(CASE WHEN 거래구분 = '이체' THEN 1 END) AS 이체건수,
    ROUND(AVG(CASE WHEN 거래구분 = '입금' THEN 거래금액 END), 0) AS 입금평균금액,
    ROUND(AVG(CASE WHEN 거래구분 = '출금' THEN 거래금액 END), 0) AS 출금평균금액
FROM 계좌거래내역 T, 계좌기본 A
WHERE T.거래일자 = TO_DATE('20240315', 'YYYYMMDD')
  AND T.거래상태 = 'NORMAL'
  AND T.계좌번호 = A.계좌번호
  AND A.활성여부 = 'Y'
GROUP BY 상품유형
ORDER BY 상품유형;

-- 거래구분별 분포 확인
SELECT 거래구분, COUNT(*) 건수, 
       ROUND(AVG(거래금액), 0) 평균금액,
       MIN(거래금액) 최소금액,
       MAX(거래금액) 최대금액
FROM 계좌거래내역
WHERE 거래일자 = TO_DATE('20240315', 'YYYYMMDD')
  AND 거래상태 = 'NORMAL'
GROUP BY 거래구분
ORDER BY 거래구분;

-- VIP 고객별 계좌 분포 확인
SELECT C.고객등급, A.상품유형, COUNT(*) 계좌수
FROM 고객정보 C, 계좌기본 A
WHERE C.고객번호 = A.고객번호
  AND C.고객등급 = 'VIP'
  AND A.활성여부 = 'Y'
GROUP BY C.고객등급, A.상품유형
ORDER BY 3 DESC;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 11 UNION → CASE WHEN 통합 실습 완료 ***