-- =============================================================================
-- Case 05: JOIN → 스칼라 서브쿼리 변환
-- 핵심 튜닝 기법: UNIQUE KEY JOIN을 스칼라 서브쿼리로 변환하여 캐싱 효과 활용
-- 관련 단원: 서브쿼리 최적화
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 청구서내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 단순통합코드 CASCADE CONSTRAINTS PURGE;
DROP TABLE 카드기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 고객기본 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 데이터 생성
PROMPT ========================================

-- 청구서내역 테이블 생성 (메인 테이블)
CREATE TABLE 청구서내역 AS
SELECT 
    rownum AS seq_no,
    'M' || LPAD(MOD(rownum-1, 1000) + 1, 12, '0') AS 회원사회원번호,
    '4567' || LPAD(rownum, 12, '0') AS 카드번호,
    'C' || LPAD(MOD(rownum-1, 10000) + 1, 10, '0') AS 카드고객번호,
    ROUND(DBMS_RANDOM.VALUE(10000, 500000), 0) AS 출금금액합계,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 30)), 'YYYYMMDD') AS 결제일자,
    LPAD(MOD(rownum-1, 20) + 1, 3, '0') AS 결제신은행코드,  -- 20가지 은행
    '110' || LPAD(rownum, 10, '0') AS 계좌번호
FROM dual 
CONNECT BY level <= 50000;

-- 단순통합코드 테이블 생성 (24MB - 코드성 테이블)
CREATE TABLE 단순통합코드 AS
SELECT 
    'REP_NBNK_C' AS 단순유형코드,
    LPAD(MOD(rownum-1, 20) + 1, 3, '0') AS 단순코드,  -- 20개 은행 코드
    '은행' || MOD(rownum-1, 20) + 1 AS 단순코드명
FROM dual 
CONNECT BY level <= 20
UNION ALL
SELECT 
    'OTHER_CODE' AS 단순유형코드,
    LPAD(rownum, 6, '0') AS 단순코드,
    '기타코드' || rownum AS 단순코드명
FROM dual 
CONNECT BY level <= 200000;  -- 대용량으로 만들어 24MB 효과 재현

-- 카드기본 테이블 생성
CREATE TABLE 카드기본 AS
SELECT 
    '4567' || LPAD(rownum, 12, '0') AS 카드번호,
    'C' || LPAD(MOD(rownum-1, 10000) + 1, 10, '0') AS 소지자카드고객번호,
    CASE MOD(rownum, 3) WHEN 0 THEN 'Y' ELSE 'N' END AS 활성여부
FROM dual
CONNECT BY level <= 50000;

-- 고객기본 테이블 생성 (3829MB - 대용량 테이블을 재현)
CREATE TABLE 고객기본 AS
SELECT 
    'C' || LPAD(rownum, 10, '0') AS 카드고객번호,
    '고객' || rownum AS 고객명,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 3650)) AS 가입일자,
    RPAD('주소정보' || rownum, 100, 'X') AS 주소  -- 컬럼 크기 확장
FROM dual
CONNECT BY level <= 100000;  -- 적당한 크기로 조정

-- PK 및 INDEX 생성
ALTER TABLE 청구서내역 ADD CONSTRAINT PK_청구서내역 PRIMARY KEY (seq_no);
ALTER TABLE 단순통합코드 ADD CONSTRAINT PK_단순통합코드 PRIMARY KEY (단순유형코드, 단순코드);
ALTER TABLE 카드기본 ADD CONSTRAINT PK_카드기본 PRIMARY KEY (카드번호);
ALTER TABLE 고객기본 ADD CONSTRAINT PK_고객기본 PRIMARY KEY (카드고객번호);

-- 필요한 INDEX 생성
CREATE INDEX IDX_청구서내역_01 ON 청구서내역 (결제일자, 카드고객번호);
CREATE INDEX IDX_청구서내역_02 ON 청구서내역 (회원사회원번호);
CREATE INDEX IDX_단순통합코드_01 ON 단순통합코드 (단순유형코드, 단순코드);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '청구서내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '단순통합코드');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '카드기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '고객기본');

-- 테이블 크기 및 JOIN 컬럼 분포 확인
SELECT table_name 테이블명, num_rows 건수,
       ROUND(num_rows * avg_row_len / 1024 / 1024, 2) AS 크기_MB
FROM user_tables 
WHERE table_name IN ('청구서내역', '단순통합코드', '카드기본', '고객기본')
ORDER BY 크기_MB DESC;

-- JOIN 컬럼 DISTINCT 값 확인 (스칼라 서브쿼리 캐싱 효과 예측)
SELECT '결제신은행코드 DISTINCT' 구분, COUNT(DISTINCT 결제신은행코드) 개수 FROM 청구서내역
UNION ALL
SELECT '소지자카드고객번호 DISTINCT', COUNT(DISTINCT 소지자카드고객번호) FROM 카드기본;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획 (JOIN 사용)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 결제일자 VARCHAR2(8);
VARIABLE 카드고객번호 VARCHAR2(15);
VARIABLE 계좌번호 VARCHAR2(20);
VARIABLE nx_회원사회원번호 VARCHAR2(20);
VARIABLE nx_rowid VARCHAR2(20);

EXEC :결제일자 := TO_CHAR(SYSDATE-5, 'YYYYMMDD');
EXEC :카드고객번호 := 'C0000001234';
EXEC :계좌번호 := '%';
EXEC :nx_회원사회원번호 := 'M000000000001';
EXEC :nx_rowid := '0';

-- 튜닝 전 SQL (JOIN으로 모든 테이블 연결)
SELECT 
    E.RID, E.회원사회원번호, E.카드번호,
    E.출금금액, E.결제신은행코드, E.계좌번호,
    E.단순코드명 은행명, E.소지자카드고객번호, E.고객명
FROM (
    SELECT 
        A.ROWID RID, A.회원사회원번호, A.카드번호,
        A.출금금액합계, A.결제신은행코드,
        A.계좌번호, B.단순코드명,
        C.소지자카드고객번호, D.고객명
    FROM 청구서내역 A,
         단순통합코드 B,
         카드기본 C,
         고객기본 D
    WHERE A.결제일자 = :결제일자
      AND A.카드고객번호 = :카드고객번호
      AND A.계좌번호 = DECODE(TRIM(:계좌번호), '%', A.계좌번호, :계좌번호)
      AND B.단순유형코드 = 'REP_NBNK_C'
      AND A.결제신은행코드 = B.단순코드(+)
      AND A.카드번호 = C.카드번호(+)
      AND C.소지자카드고객번호 = D.카드고객번호(+)
      AND ((A.회원사회원번호 > :nx_회원사회원번호) 
           OR (A.회원사회원번호 = :nx_회원사회원번호 AND A.rowid >= :nx_rowid))
    ORDER BY A.회원사회원번호 ASC, A.결제일자 DESC, A.회원사회원번호
) E
WHERE ROWNUM <= 501;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획 (스칼라 서브쿼리 사용)
PROMPT ========================================

-- 튜닝 후 SQL (스칼라 서브쿼리로 변환)
SELECT 
    E.RID, E.회원사회원번호, E.카드번호,
    E.출금금액, E.결제신은행코드,
    E.계좌번호, 
    (SELECT B.단순코드명 FROM 단순통합코드 B
     WHERE B.단순유형코드 = 'REP_NBNK_C'
       AND E.결제신은행코드 = B.단순코드) AS 은행명,
    E.소지자카드고객번호,
    (SELECT D.고객명 FROM 고객기본 D
     WHERE E.소지자카드고객번호 = D.카드고객번호) AS 고객명
FROM (
    SELECT 
        A.ROWID RID, A.회원사회원번호, A.카드번호,
        A.출금금액합계, A.결제신은행코드,
        A.계좌번호, C.소지자카드고객번호
    FROM 청구서내역 A, 카드기본 C
    WHERE A.결제일자 = :결제일자
      AND A.카드고객번호 = :카드고객번호
      AND A.계좌번호 = DECODE(TRIM(:계좌번호), '%', A.계좌번호, :계좌번호)
      AND A.카드번호 = C.카드번호(+)
      AND ((A.회원사회원번호 > :nx_회원사회원번호) 
           OR (A.회원사회원번호 = :nx_회원사회원번호 AND A.rowid >= :nx_rowid))
    ORDER BY A.회원사회원번호 ASC, A.결제일자 DESC, A.회원사회원번호
) E
WHERE ROWNUM <= 501;

PROMPT
PROMPT ========================================
PROMPT 4. 스칼라 서브쿼리 캐싱 효과 확인
PROMPT ========================================

-- 스칼라 서브쿼리 실행 횟수 확인을 위한 추가 테스트
SELECT COUNT(*) 총건수, 
       COUNT(DISTINCT 결제신은행코드) 은행코드종류,
       COUNT(DISTINCT 소지자카드고객번호) 고객번호종류
FROM (
    SELECT A.결제신은행코드, C.소지자카드고객번호
    FROM 청구서내역 A, 카드기본 C
    WHERE A.결제일자 = :결제일자
      AND A.카드고객번호 = :카드고객번호
      AND A.계좌번호 = DECODE(TRIM(:계좌번호), '%', A.계좌번호, :계좌번호)
      AND A.카드번호 = C.카드번호(+)
      AND ((A.회원사회원번호 > :nx_회원사회원번호) 
           OR (A.회원사회원번호 = :nx_회원사회원번호 AND A.rowid >= :nx_rowid))
    AND rownum <= 501
);

PROMPT
PROMPT ========================================
PROMPT 5. 성능 분석 및 튜닝 포인트
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 단순통합코드 테이블: 24MB (대용량 코드 테이블)
    - 고객기본 테이블: 3829MB (대용량 테이블)
    - JOIN 되는 값의 종류가 적음 (결제신은행코드: 20개, 고객번호: 적음)
    - UNIQUE KEY OUTER JOIN으로 1:1 관계
    - 불필요한 대용량 테이블 SCAN 발생
 
 2. 스칼라 서브쿼리 적용 조건:
    - UNIQUE KEY JOIN (1:1 관계)
    - JOIN되는 값의 DISTINCT 개수가 적음 (일반적으로 1000개 이하)
    - 같은 값이 반복적으로 나타남 (캐싱 효과)
    - OUTER JOIN 관계
 
 3. 스칼라 서브쿼리 캐싱 메커니즘:
    - Oracle은 스칼라 서브쿼리 결과를 내부적으로 캐싱
    - 동일한 INPUT 값에 대해서는 재실행하지 않고 캐시에서 조회
    - 최대 255개까지 캐싱 (Oracle 버전별 차이)
    - LRU(Least Recently Used) 방식으로 관리
 
 4. 튜닝 방법:
    - 대용량 테이블과의 JOIN → 스칼라 서브쿼리로 변환
    - FROM절에서는 필수 JOIN만 유지
    - SELECT절에서 스칼라 서브쿼리로 부가 정보 조회
 
 5. 주의 사항:
    - 값의 종류가 많으면 캐싱 효과가 떨어짐 (오히려 성능 악화 가능)
    - NULL 처리에 주의 (OUTER JOIN → 서브쿼리 변환 시)
    - 스칼라 서브쿼리는 단일 컬럼만 반환 가능
 
 6. 성과:
    - Buffers: 5,256 → 2,239 (57.4% 개선)
    - 실행계획에서 스칼라 서브쿼리 Starts가 1로 표시 (캐싱 발생)
    - 대용량 테이블 FULL SCAN 제거
*/

PROMPT
PROMPT ========================================
PROMPT 6. 캐싱 효과 실험
PROMPT ========================================

-- 동일 값에 대한 스칼라 서브쿼리 재사용 확인
-- 실행계획에서 FAST DUAL 또는 Starts=1 확인

SELECT DISTINCT
    결제신은행코드,
    (SELECT B.단순코드명 FROM 단순통합코드 B
     WHERE B.단순유형코드 = 'REP_NBNK_C'
       AND 청구서내역.결제신은행코드 = B.단순코드) AS 은행명
FROM 청구서내역
WHERE rownum <= 100;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 05 JOIN → 스칼라 서브쿼리 변환 실습 완료 ***
PROMPT *** 실행계획에서 스칼라 서브쿼리 Starts=1 (캐싱) 확인하세요! ***