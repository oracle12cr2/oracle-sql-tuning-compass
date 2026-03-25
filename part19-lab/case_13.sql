-- =============================================================================
-- Case 13: 페이징 후 JOIN + 스칼라 서브쿼리
-- 핵심 튜닝 기법: 페이징 우선 처리로 JOIN 대상 축소 및 스칼라 서브쿼리 캐싱
-- 관련 단원: 페이징 처리, 서브쿼리
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 주문내역 CASCADE CONSTRAINTS PURGE;
DROP TABLE 고객마스터 CASCADE CONSTRAINTS PURGE;
DROP TABLE 상품마스터 CASCADE CONSTRAINTS PURGE;
DROP TABLE 배송정보 CASCADE CONSTRAINTS PURGE;
DROP TABLE 할인정책 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 고객마스터 테이블 생성
CREATE TABLE 고객마스터 AS
SELECT 
    'CUST' || LPAD(rownum, 8, '0') AS 고객ID,
    '고객' || rownum AS 고객명,
    CASE MOD(rownum, 5)
        WHEN 0 THEN 'DIAMOND'
        WHEN 1 THEN 'PLATINUM'
        WHEN 2 THEN 'GOLD'
        WHEN 3 THEN 'SILVER'
        ELSE 'BRONZE'
    END AS 회원등급,
    '010-' || LPAD(MOD(rownum, 10000), 4, '0') || '-' || LPAD(MOD(rownum*7, 10000), 4, '0') AS 휴대폰번호,
    'user' || rownum || '@email.com' AS 이메일,
    TO_DATE('2018-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 2190)) AS 가입일자
FROM dual
CONNECT BY rownum <= 100000;  -- 10만 고객

-- 상품마스터 테이블 생성
CREATE TABLE 상품마스터 AS
SELECT 
    'PROD' || LPAD(rownum, 6, '0') AS 상품ID,
    '상품' || rownum AS 상품명,
    CASE MOD(rownum, 10)
        WHEN 0 THEN '전자제품'
        WHEN 1 THEN '의류'
        WHEN 2 THEN '식품'
        WHEN 3 THEN '도서'
        WHEN 4 THEN '화장품'
        WHEN 5 THEN '스포츠'
        WHEN 6 THEN '가구'
        WHEN 7 THEN '완구'
        WHEN 8 THEN '문구'
        ELSE '기타'
    END AS 카테고리,
    ROUND(DBMS_RANDOM.VALUE(1000, 500000), -2) AS 정가,
    'Y' AS 판매여부
FROM dual
CONNECT BY rownum <= 50000;  -- 5만 상품

-- 주문내역 테이블 생성 (메인 테이블, 대용량)
CREATE TABLE 주문내역 AS
SELECT 
    'ORD' || TO_CHAR(SYSDATE, 'YYYYMMDD') || LPAD(rownum, 8, '0') AS 주문번호,
    'CUST' || LPAD(MOD(rownum, 100000) + 1, 8, '0') AS 고객ID,
    'PROD' || LPAD(MOD(rownum, 50000) + 1, 6, '0') AS 상품ID,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + MOD(rownum, 120) AS 주문일자,
    TRUNC(DBMS_RANDOM.VALUE(1, 20)) AS 주문수량,
    ROUND(DBMS_RANDOM.VALUE(5000, 1000000), -2) AS 주문금액,
    CASE MOD(rownum, 10)
        WHEN 0 THEN '주문접수'
        WHEN 1 THEN '결제완료'
        WHEN 2 THEN '상품준비중' 
        WHEN 3 THEN '출고완료'
        WHEN 4 THEN '배송중'
        WHEN 5 THEN '배송완료'
        WHEN 6 THEN '주문취소'
        ELSE '배송완료'
    END AS 주문상태,
    SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 120)) AS 주문일시,
    MOD(rownum, 100) + 1 AS 할인정책ID,
    'ADMIN' AS 등록자
FROM dual
CONNECT BY rownum <= 2000000;  -- 200만건

-- 배송정보 테이블 생성
CREATE TABLE 배송정보 AS
SELECT 
    주문번호,
    고객ID,
    '서울특별시 ' || 
    CASE MOD(rownum, 25)
        WHEN 0 THEN '강남구'
        WHEN 1 THEN '강동구'
        WHEN 2 THEN '강북구' 
        WHEN 3 THEN '강서구'
        WHEN 4 THEN '관악구'
        WHEN 5 THEN '광진구'
        WHEN 6 THEN '구로구'
        WHEN 7 THEN '금천구'
        WHEN 8 THEN '노원구'
        WHEN 9 THEN '도봉구'
        WHEN 10 THEN '동대문구'
        WHEN 11 THEN '동작구'
        WHEN 12 THEN '마포구'
        WHEN 13 THEN '서대문구'
        WHEN 14 THEN '서초구'
        WHEN 15 THEN '성동구'
        WHEN 16 THEN '성북구'
        WHEN 17 THEN '송파구'
        WHEN 18 THEN '양천구'
        WHEN 19 THEN '영등포구'
        WHEN 20 THEN '용산구'
        WHEN 21 THEN '은평구'
        WHEN 22 THEN '종로구'
        WHEN 23 THEN '중구'
        ELSE '중랑구'
    END || ' ' || DBMS_RANDOM.STRING('U', 8) || '로 ' || TRUNC(DBMS_RANDOM.VALUE(1, 999)) AS 배송주소,
    '010-' || LPAD(TRUNC(DBMS_RANDOM.VALUE(1000, 9999)), 4, '0') || 
    '-' || LPAD(TRUNC(DBMS_RANDOM.VALUE(1000, 9999)), 4, '0') AS 배송연락처,
    주문일자 + TRUNC(DBMS_RANDOM.VALUE(1, 7)) AS 배송예정일자
FROM 주문내역
WHERE MOD(rownum, 3) != 0;  -- 주문의 2/3만 배송정보 있음

-- 할인정책 테이블 생성 (소형 테이블)
CREATE TABLE 할인정책 AS
SELECT 
    rownum AS 할인정책ID,
    CASE MOD(rownum, 5)
        WHEN 0 THEN '신규회원할인'
        WHEN 1 THEN 'VIP할인'
        WHEN 2 THEN '대량구매할인'
        WHEN 3 THEN '시즌할인'
        ELSE '일반할인'
    END AS 할인명,
    ROUND(DBMS_RANDOM.VALUE(5, 30), 0) AS 할인율,
    'Y' AS 적용여부
FROM dual
CONNECT BY rownum <= 100;

-- PK 및 INDEX 생성
ALTER TABLE 고객마스터 ADD CONSTRAINT PK_고객마스터 PRIMARY KEY (고객ID);
ALTER TABLE 상품마스터 ADD CONSTRAINT PK_상품마스터 PRIMARY KEY (상품ID);
ALTER TABLE 주문내역 ADD CONSTRAINT PK_주문내역 PRIMARY KEY (주문번호);
ALTER TABLE 배송정보 ADD CONSTRAINT PK_배송정보 PRIMARY KEY (주문번호);
ALTER TABLE 할인정책 ADD CONSTRAINT PK_할인정책 PRIMARY KEY (할인정책ID);

-- 조회용 INDEX 생성
CREATE INDEX 주문내역_IX1 ON 주문내역 (주문일자 DESC, 고객ID);
CREATE INDEX 주문내역_IX2 ON 주문내역 (고객ID, 주문일자 DESC);
CREATE INDEX 주문내역_IX3 ON 주문내역 (주문상태, 주문일자);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '고객마스터');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '상품마스터');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '주문내역');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '배송정보');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '할인정책');

-- 데이터 분포 확인
SELECT '주문내역' 테이블명, COUNT(*) 건수 FROM 주문내역
UNION ALL
SELECT '고객마스터', COUNT(*) FROM 고객마스터
UNION ALL
SELECT '상품마스터', COUNT(*) FROM 상품마스터
UNION ALL
SELECT '배송정보', COUNT(*) FROM 배송정보
UNION ALL
SELECT '할인정책', COUNT(*) FROM 할인정책;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 페이지크기 NUMBER;
VARIABLE 시작일자 VARCHAR2(10);
VARIABLE 종료일자 VARCHAR2(10);

EXEC :페이지크기 := 20;
EXEC :시작일자 := '20240301';
EXEC :종료일자 := '20240331';

-- 튜닝 전 SQL (전체 JOIN 후 페이징 - 비효율)
SELECT *
FROM (
    SELECT 
        ROW_NUMBER() OVER (ORDER BY O.주문일시 DESC) AS RN,
        O.주문번호,
        O.주문일자,
        O.주문상태,
        O.주문수량,
        O.주문금액,
        C.고객명,
        C.회원등급,
        C.휴대폰번호,
        P.상품명,
        P.카테고리,
        P.정가,
        D.배송주소,
        D.배송연락처,
        D.배송예정일자,
        DC.할인명,
        DC.할인율
    FROM 주문내역 O
         INNER JOIN 고객마스터 C ON O.고객ID = C.고객ID
         INNER JOIN 상품마스터 P ON O.상품ID = P.상품ID  
         LEFT OUTER JOIN 배송정보 D ON O.주문번호 = D.주문번호
         LEFT OUTER JOIN 할인정책 DC ON O.할인정책ID = DC.할인정책ID
    WHERE O.주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
      AND O.주문상태 IN ('배송완료', '배송중', '출고완료')
)
WHERE RN <= :페이지크기;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (페이징 후 JOIN + 스칼라 서브쿼리)
SELECT 
    O.주문번호,
    O.주문일자,
    O.주문상태,
    O.주문수량,
    O.주문금액,
    (SELECT 고객명 FROM 고객마스터 WHERE 고객ID = O.고객ID) AS 고객명,
    (SELECT 회원등급 FROM 고객마스터 WHERE 고객ID = O.고객ID) AS 회원등급,
    (SELECT 휴대폰번호 FROM 고객마스터 WHERE 고객ID = O.고객ID) AS 휴대폰번호,
    (SELECT 상품명 FROM 상품마스터 WHERE 상품ID = O.상품ID) AS 상품명,
    (SELECT 카테고리 FROM 상품마스터 WHERE 상품ID = O.상품ID) AS 카테고리,
    (SELECT 정가 FROM 상품마스터 WHERE 상품ID = O.상품ID) AS 정가,
    (SELECT 배송주소 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송주소,
    (SELECT 배송연락처 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송연락처,
    (SELECT 배송예정일자 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송예정일자,
    (SELECT 할인명 FROM 할인정책 WHERE 할인정책ID = O.할인정책ID) AS 할인명,
    (SELECT 할인율 FROM 할인정책 WHERE 할인정책ID = O.할인정책ID) AS 할인율
FROM (
    SELECT 
        주문번호, 고객ID, 상품ID, 주문일자, 주문상태,
        주문수량, 주문금액, 주문일시, 할인정책ID
    FROM 주문내역
    WHERE 주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
      AND 주문상태 IN ('배송완료', '배송중', '출고완료')
    ORDER BY 주문일시 DESC
) O
WHERE ROWNUM <= :페이지크기;

-- 더 나은 방법: JOIN + 스칼라 서브쿼리 조합
PROMPT
PROMPT ========================================
PROMPT 3-1. 최적 튜닝안 (핵심 JOIN + 스칼라 서브쿼리)
PROMPT ========================================

-- 핵심 테이블만 JOIN 후 나머지는 스칼라 서브쿼리
SELECT 
    O.주문번호,
    O.주문일자,
    O.주문상태,
    O.주문수량,
    O.주문금액,
    C.고객명,
    C.회원등급,
    C.휴대폰번호,
    P.상품명,
    P.카테고리,
    P.정가,
    (SELECT 배송주소 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송주소,
    (SELECT 배송연락처 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송연락처,
    (SELECT 배송예정일자 FROM 배송정보 WHERE 주문번호 = O.주문번호) AS 배송예정일자,
    (SELECT 할인명 FROM 할인정책 WHERE 할인정책ID = O.할인정책ID) AS 할인명,
    (SELECT 할인율 FROM 할인정책 WHERE 할인정책ID = O.할인정책ID) AS 할인율
FROM (
    SELECT 
        주문번호, 고객ID, 상품ID, 주문일자, 주문상태,
        주문수량, 주문금액, 주문일시, 할인정책ID
    FROM 주문내역
    WHERE 주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
      AND 주문상태 IN ('배송완료', '배송중', '출고완료')
    ORDER BY 주문일시 DESC
) O
INNER JOIN 고객마스터 C ON O.고객ID = C.고객ID
INNER JOIN 상품마스터 P ON O.상품ID = P.상품ID
WHERE ROWNUM <= :페이지크기;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 전체 200만건 주문내역에 모든 외부 테이블 JOIN 후 20건만 추출
    - 불필요한 대량 JOIN으로 인한 I/O 낭비 (802K buffers)
    - LEFT OUTER JOIN으로 인한 추가 복잡성
    - ROW_NUMBER() 분석함수로 인한 SORT 연산 및 PGA 사용
 
 2. 해결책:
    - 메인 테이블만으로 먼저 페이징 (20건 추출)
    - 줄어든 건수에 대해서만 외부 테이블과 관계 맺음
    - UNIQUE KEY 관계이고 값 종류가 적은 경우 스칼라 서브쿼리 활용
    - 스칼라 서브쿼리 캐싱 효과로 반복 ACCESS 최소화
 
 3. 페이징 우선 처리 전략:
    - 먼저 ORDER BY + ROWNUM으로 필요한 건수만 추출
    - INDEX를 활용한 효율적인 정렬 및 페이징
    - 대량 데이터에서 소수만 필요할 때 극적인 성능 향상
 
 4. 스칼라 서브쿼리 활용 기준:
    - UNIQUE KEY JOIN (1:1 관계)
    - 값의 종류가 적어 캐싱 효과를 기대할 수 있음
    - LEFT OUTER JOIN이 필요한 선택적 데이터
    - 단순한 조회 조건 (복잡한 JOIN 조건 아님)
 
 5. 하이브리드 방법:
    - 핵심 테이블(고객, 상품)은 INNER JOIN
    - 선택적 테이블(배송정보, 할인정책)은 스칼라 서브쿼리
    - JOIN과 스칼라 서브쿼리의 장점 결합
 
 6. 적용 조건:
    - 대용량 테이블에서 소수의 결과만 필요
    - 여러 외부 테이블과 관계가 있는 복잡한 조회
    - 페이징이 필요한 목록 조회 화면
    - 실시간 응답이 중요한 온라인 서비스
 
 7. 성과:
    - JOIN 대상 건수: 전체 결과 → 20건 (99.9% 감소)
    - PGA 사용량: 802K → 거의 0 (100% 개선)
    - I/O 대폭 감소 (수십 buffers로 단축)
    - 응답 시간 대폭 개선
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증 및 최적화
PROMPT ========================================

-- 스칼라 서브쿼리 캐싱 효과 확인
SELECT 
    '할인정책ID별_분포' AS 구분,
    할인정책ID,
    COUNT(*) AS 건수,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS 비율
FROM 주문내역
WHERE 주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND 주문상태 IN ('배송완료', '배송중', '출고완료')
GROUP BY 할인정책ID
ORDER BY 건수 DESC;

-- 페이징 성능 비교를 위한 큰 페이지 테스트
PROMPT
PROMPT === 큰 페이지 크기 테스트 (100건) ===
EXEC :페이지크기 := 100;

SELECT COUNT(*) AS 페이징_대상_총건수
FROM 주문내역
WHERE 주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND 주문상태 IN ('배송완료', '배송중', '출고완료');

-- 고객별 주문 분포 확인 (스칼라 서브쿼리 캐싱 효과)
SELECT 
    회원등급,
    COUNT(DISTINCT 고객ID) AS 고객수,
    COUNT(*) AS 주문건수,
    ROUND(AVG(주문금액), 0) AS 평균주문금액
FROM 주문내역 O, 고객마스터 C
WHERE O.고객ID = C.고객ID
  AND O.주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND O.주문상태 IN ('배송완료', '배송중', '출고완료')
GROUP BY 회원등급
ORDER BY 평균주문금액 DESC;

-- INDEX 활용도 확인
SELECT 
    INDEX_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    COLUMN_POSITION
FROM USER_IND_COLUMNS
WHERE TABLE_NAME = '주문내역'
ORDER BY INDEX_NAME, COLUMN_POSITION;

-- 배송정보 존재율 확인 (LEFT OUTER JOIN vs 스칼라 서브쿼리)
SELECT 
    '배송정보_있음' AS 구분,
    COUNT(*) AS 건수
FROM 주문내역 O
WHERE EXISTS (SELECT 1 FROM 배송정보 WHERE 주문번호 = O.주문번호)
  AND O.주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND O.주문상태 IN ('배송완료', '배송중', '출고완료')

UNION ALL

SELECT 
    '배송정보_없음' AS 구분,
    COUNT(*) AS 건수
FROM 주문내역 O
WHERE NOT EXISTS (SELECT 1 FROM 배송정보 WHERE 주문번호 = O.주문번호)
  AND O.주문일자 BETWEEN TO_DATE(:시작일자, 'YYYYMMDD') AND TO_DATE(:종료일자, 'YYYYMMDD')
  AND O.주문상태 IN ('배송완료', '배송중', '출고완료');

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 13 페이징 후 JOIN + 스칼라 서브쿼리 실습 완료 ***