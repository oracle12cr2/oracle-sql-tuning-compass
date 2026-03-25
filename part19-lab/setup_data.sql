-- =============================================================================
-- Part 19 공통 데이터 세트 구축
-- 목적: 16개 사례에서 공통으로 사용할 관계형 스키마 및 데이터 생성
-- 환경: Oracle 19c RAC, APP_USER 스키마
-- 예상 소요시간: 10~15분
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET PAGESIZE 50
SET LINESIZE 200

PROMPT
PROMPT ========================================
PROMPT Part 19 공통 데이터 세트 구축 시작
PROMPT 예상 소요시간: 10~15분
PROMPT ========================================

-- 1. 기존 테이블 DROP (IF EXISTS 패턴)
BEGIN
    FOR rec IN (SELECT table_name FROM user_tables WHERE table_name IN (
        'T_CUSTOMER', 'T_ORDER', 'T_ORDER_DETAIL', 'T_PRODUCT', 'T_CATEGORY',
        'T_CODE', 'T_STORE', 'T_LOG', 'T_BOARD', 'T_DEPT', 'T_STATUS', 'T_DAILY_SALES'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

PROMPT
PROMPT ========================================
PROMPT 2. 테이블 생성
PROMPT ========================================

-- T_CUSTOMER (고객) - 10만건
CREATE TABLE T_CUSTOMER (
    cust_id       NUMBER(10)    NOT NULL,
    cust_name     VARCHAR2(50)  NOT NULL,
    region        VARCHAR2(10)  NOT NULL,
    grade         VARCHAR2(10)  NOT NULL,
    join_date     DATE          NOT NULL,
    status        VARCHAR2(10)  DEFAULT 'ACTIVE',
    CONSTRAINT PK_CUSTOMER PRIMARY KEY (cust_id)
) NOLOGGING;

-- T_STORE (매장) - 1000건  
CREATE TABLE T_STORE (
    store_id      NUMBER(10)    NOT NULL,
    store_name    VARCHAR2(50)  NOT NULL,
    region_code   VARCHAR2(10)  NOT NULL,
    open_date     DATE          NOT NULL,
    CONSTRAINT PK_STORE PRIMARY KEY (store_id)
) NOLOGGING;

-- T_CATEGORY (카테고리) - 50건
CREATE TABLE T_CATEGORY (
    cat_id        NUMBER(10)    NOT NULL,
    cat_name      VARCHAR2(50)  NOT NULL,
    cat_type      VARCHAR2(20)  NOT NULL,
    parent_cat_id NUMBER(10),
    CONSTRAINT PK_CATEGORY PRIMARY KEY (cat_id)
) NOLOGGING;

-- T_PRODUCT (상품) - 5만건
CREATE TABLE T_PRODUCT (
    prod_id       NUMBER(10)    NOT NULL,
    prod_name     VARCHAR2(100) NOT NULL,
    cat_id        NUMBER(10)    NOT NULL,
    price         NUMBER(12,2)  NOT NULL,
    status        VARCHAR2(10)  DEFAULT 'ACTIVE',
    CONSTRAINT PK_PRODUCT PRIMARY KEY (prod_id)
) NOLOGGING;

-- T_ORDER (주문 헤더) - 100만건
CREATE TABLE T_ORDER (
    order_id      NUMBER(12)    NOT NULL,
    cust_id       NUMBER(10)    NOT NULL,
    order_date    DATE          NOT NULL,
    status        VARCHAR2(20)  NOT NULL,
    total_amount  NUMBER(15,2)  DEFAULT 0,
    store_id      NUMBER(10)    NOT NULL,
    region_code   VARCHAR2(10)  NOT NULL,
    CONSTRAINT PK_ORDER PRIMARY KEY (order_id)
) NOLOGGING;

-- T_ORDER_DETAIL (주문 상세) - 500만건
CREATE TABLE T_ORDER_DETAIL (
    detail_id     NUMBER(15)    NOT NULL,
    order_id      NUMBER(12)    NOT NULL,
    prod_id       NUMBER(10)    NOT NULL,
    qty           NUMBER(8,2)   NOT NULL,
    unit_price    NUMBER(12,2)  NOT NULL,
    amount        NUMBER(15,2)  NOT NULL,
    cat_id        NUMBER(10)    NOT NULL,
    CONSTRAINT PK_ORDER_DETAIL PRIMARY KEY (detail_id)
) NOLOGGING;

-- T_CODE (공통코드) - 200건
CREATE TABLE T_CODE (
    code_group    VARCHAR2(20)  NOT NULL,
    code          VARCHAR2(20)  NOT NULL,
    code_name     VARCHAR2(100) NOT NULL,
    CONSTRAINT PK_CODE PRIMARY KEY (code_group, code)
) NOLOGGING;

-- T_LOG (시스템로그) - 200만건
CREATE TABLE T_LOG (
    log_id        NUMBER(15)    NOT NULL,
    log_date      DATE          NOT NULL,
    category      VARCHAR2(20)  NOT NULL,
    value         NUMBER(12,2)  NOT NULL,
    session_id    VARCHAR2(50)  NOT NULL,
    status        VARCHAR2(10)  DEFAULT 'NORMAL',
    CONSTRAINT PK_LOG PRIMARY KEY (log_id)
) NOLOGGING;

-- T_DEPT (부서) - 100건
CREATE TABLE T_DEPT (
    dept_id       NUMBER(10)    NOT NULL,
    dept_name     VARCHAR2(50)  NOT NULL,
    location      VARCHAR2(50)  NOT NULL,
    CONSTRAINT PK_DEPT PRIMARY KEY (dept_id)
) NOLOGGING;

-- T_BOARD (게시판) - 50만건
CREATE TABLE T_BOARD (
    board_id      NUMBER(12)    NOT NULL,
    title         VARCHAR2(200) NOT NULL,
    content       VARCHAR2(4000),
    dept_id       NUMBER(10)    NOT NULL,
    status        VARCHAR2(10)  DEFAULT 'ACTIVE',
    created_date  DATE          NOT NULL,
    cust_id       NUMBER(10)    NOT NULL,
    CONSTRAINT PK_BOARD PRIMARY KEY (board_id)
) NOLOGGING;

-- T_STATUS (상태코드) - 20건
CREATE TABLE T_STATUS (
    status_code   VARCHAR2(20)  NOT NULL,
    status_name   VARCHAR2(100) NOT NULL,
    CONSTRAINT PK_STATUS PRIMARY KEY (status_code)
) NOLOGGING;

-- T_DAILY_SALES (일별매출) - 300만건
CREATE TABLE T_DAILY_SALES (
    sale_date     DATE          NOT NULL,
    store_id      NUMBER(10)    NOT NULL,
    cust_id       NUMBER(10)    NOT NULL,
    sale_type     VARCHAR2(1)   NOT NULL,
    amount        NUMBER(15,2)  NOT NULL,
    region_code   VARCHAR2(10)  NOT NULL,
    cat_id        NUMBER(10)    NOT NULL
) NOLOGGING;

PROMPT
PROMPT ========================================
PROMPT 3. 데이터 생성 시작
PROMPT ========================================

-- T_CATEGORY (50건) - 먼저 생성 (FK 관계)
PROMPT 카테고리 데이터 생성...
INSERT /*+ APPEND */ INTO T_CATEGORY
SELECT 
    LEVEL                             AS cat_id,
    'Category_' || LEVEL              AS cat_name,
    CASE WHEN MOD(LEVEL, 10) = 1 THEN 'PREMIUM'
         WHEN MOD(LEVEL, 10) <= 3 THEN 'STANDARD' 
         ELSE 'ECONOMY' END           AS cat_type,
    CASE WHEN LEVEL > 10 THEN TRUNC((LEVEL-1)/10) ELSE NULL END AS parent_cat_id
FROM DUAL CONNECT BY LEVEL <= 50;

-- T_DEPT (100건)
PROMPT 부서 데이터 생성...
INSERT /*+ APPEND */ INTO T_DEPT
SELECT 
    LEVEL                                   AS dept_id,
    'Department_' || LPAD(LEVEL, 3, '0')   AS dept_name,
    CASE MOD(LEVEL, 5) 
        WHEN 0 THEN '서울'
        WHEN 1 THEN '부산'
        WHEN 2 THEN '대구'
        WHEN 3 THEN '인천'
        ELSE '광주'
    END                                     AS location
FROM DUAL CONNECT BY LEVEL <= 100;

-- T_STATUS (20건)
PROMPT 상태코드 데이터 생성...
INSERT /*+ APPEND */ INTO T_STATUS
WITH status_list AS (
    SELECT 'ACTIVE' AS status_code, '활성' AS status_name FROM DUAL UNION ALL
    SELECT 'INACTIVE', '비활성' FROM DUAL UNION ALL
    SELECT 'PENDING', '대기' FROM DUAL UNION ALL
    SELECT 'COMPLETE', '완료' FROM DUAL UNION ALL
    SELECT 'CANCEL', '취소' FROM DUAL UNION ALL
    SELECT 'HOLD', '보류' FROM DUAL UNION ALL
    SELECT 'PROCESS', '처리중' FROM DUAL UNION ALL
    SELECT 'APPROVE', '승인' FROM DUAL UNION ALL
    SELECT 'REJECT', '거부' FROM DUAL UNION ALL
    SELECT 'WAIT', '대기중' FROM DUAL UNION ALL
    SELECT 'ERROR', '오류' FROM DUAL UNION ALL
    SELECT 'SUCCESS', '성공' FROM DUAL UNION ALL
    SELECT 'FAIL', '실패' FROM DUAL UNION ALL
    SELECT 'TIMEOUT', '시간초과' FROM DUAL UNION ALL
    SELECT 'RETRY', '재시도' FROM DUAL UNION ALL
    SELECT 'SKIP', '건너뜀' FROM DUAL UNION ALL
    SELECT 'PAUSE', '일시정지' FROM DUAL UNION ALL
    SELECT 'RESUME', '재개' FROM DUAL UNION ALL
    SELECT 'STOP', '정지' FROM DUAL UNION ALL
    SELECT 'START', '시작' FROM DUAL
)
SELECT * FROM status_list;

-- T_STORE (1000건)
PROMPT 매장 데이터 생성...
INSERT /*+ APPEND */ INTO T_STORE
SELECT 
    LEVEL                               AS store_id,
    'Store_' || LPAD(LEVEL, 4, '0')    AS store_name,
    'R' || LPAD(MOD(LEVEL, 20) + 1, 2, '0') AS region_code,
    DATE '2020-01-01' + MOD(LEVEL * 7, 1825) AS open_date
FROM DUAL CONNECT BY LEVEL <= 1000;

-- T_CODE (200건)
PROMPT 공통코드 데이터 생성...
INSERT /*+ APPEND */ INTO T_CODE
WITH code_groups AS (
    SELECT 'ORDER_STATUS' AS code_group FROM DUAL UNION ALL
    SELECT 'CUSTOMER_GRADE' FROM DUAL UNION ALL
    SELECT 'REGION' FROM DUAL UNION ALL
    SELECT 'PAYMENT_TYPE' FROM DUAL UNION ALL
    SELECT 'PRODUCT_TYPE' FROM DUAL
), code_values AS (
    SELECT 
        code_group,
        LEVEL AS seq,
        CASE code_group
            WHEN 'ORDER_STATUS' THEN 
                CASE LEVEL WHEN 1 THEN 'ACTIVE' WHEN 2 THEN 'COMPLETE' 
                          WHEN 3 THEN 'CANCEL' ELSE 'PENDING' END
            WHEN 'CUSTOMER_GRADE' THEN 
                CASE LEVEL WHEN 1 THEN 'VIP' WHEN 2 THEN 'GOLD' 
                          WHEN 3 THEN 'SILVER' ELSE 'NORMAL' END
            WHEN 'REGION' THEN 'R' || LPAD(LEVEL, 2, '0')
            WHEN 'PAYMENT_TYPE' THEN 
                CASE LEVEL WHEN 1 THEN 'CARD' WHEN 2 THEN 'CASH' 
                          WHEN 3 THEN 'POINT' ELSE 'BANK' END
            ELSE 'TYPE_' || LEVEL
        END AS code,
        CASE code_group
            WHEN 'ORDER_STATUS' THEN 
                CASE LEVEL WHEN 1 THEN '주문접수' WHEN 2 THEN '주문완료' 
                          WHEN 3 THEN '주문취소' ELSE '처리대기' END
            WHEN 'CUSTOMER_GRADE' THEN 
                CASE LEVEL WHEN 1 THEN 'VIP고객' WHEN 2 THEN '골드고객' 
                          WHEN 3 THEN '실버고객' ELSE '일반고객' END
            WHEN 'REGION' THEN '지역_' || LEVEL
            WHEN 'PAYMENT_TYPE' THEN 
                CASE LEVEL WHEN 1 THEN '카드결제' WHEN 2 THEN '현금결제' 
                          WHEN 3 THEN '포인트결제' ELSE '계좌이체' END
            ELSE '유형_' || LEVEL || '번'
        END AS code_name
    FROM code_groups, (SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= 40)
    WHERE NOT (code_group = 'ORDER_STATUS' AND LEVEL > 4)
    AND NOT (code_group = 'CUSTOMER_GRADE' AND LEVEL > 4)  
    AND NOT (code_group = 'REGION' AND LEVEL > 20)
    AND NOT (code_group = 'PAYMENT_TYPE' AND LEVEL > 4)
    AND NOT (code_group = 'PRODUCT_TYPE' AND LEVEL > 10)
)
SELECT code_group, code, code_name FROM code_values;

COMMIT;

-- T_CUSTOMER (10만건)
PROMPT 고객 데이터 생성... (10만건)
INSERT /*+ APPEND */ INTO T_CUSTOMER
SELECT 
    LEVEL                                     AS cust_id,
    'Customer_' || LPAD(LEVEL, 6, '0')       AS cust_name,
    'R' || LPAD(MOD(LEVEL, 20) + 1, 2, '0') AS region,
    CASE WHEN MOD(LEVEL, 100) <= 5 THEN 'VIP'
         WHEN MOD(LEVEL, 100) <= 20 THEN 'GOLD'
         WHEN MOD(LEVEL, 100) <= 45 THEN 'SILVER'
         ELSE 'NORMAL' END                    AS grade,
    DATE '2020-01-01' + MOD(LEVEL * 3, 2215) AS join_date,
    CASE WHEN MOD(LEVEL, 50) = 1 THEN 'INACTIVE' ELSE 'ACTIVE' END AS status
FROM DUAL CONNECT BY LEVEL <= 100000;

COMMIT;

-- T_PRODUCT (5만건)  
PROMPT 상품 데이터 생성... (5만건)
INSERT /*+ APPEND */ INTO T_PRODUCT
SELECT 
    LEVEL                                  AS prod_id,
    'Product_' || LPAD(LEVEL, 5, '0')     AS prod_name,
    MOD(LEVEL, 50) + 1                    AS cat_id,
    ROUND(DBMS_RANDOM.VALUE(1000, 50000), -1) AS price,
    CASE WHEN MOD(LEVEL, 100) <= 5 THEN 'INACTIVE' ELSE 'ACTIVE' END AS status
FROM DUAL CONNECT BY LEVEL <= 50000;

COMMIT;

-- T_ORDER (100만건)
PROMPT 주문 데이터 생성... (100만건)
INSERT /*+ APPEND */ INTO T_ORDER
SELECT 
    LEVEL                                       AS order_id,
    MOD(LEVEL, 100000) + 1                     AS cust_id,
    DATE '2024-01-01' + MOD(LEVEL * 2, 815)    AS order_date,
    CASE MOD(LEVEL, 100)
        WHEN 0 THEN 'CANCEL'
        WHEN 1 THEN 'PENDING'  
        WHEN 2 THEN 'ACTIVE'
        ELSE 'COMPLETE' END                     AS status,
    ROUND(DBMS_RANDOM.VALUE(10000, 500000), -2) AS total_amount,
    MOD(LEVEL, 1000) + 1                       AS store_id,
    'R' || LPAD(MOD(LEVEL, 20) + 1, 2, '0')   AS region_code
FROM DUAL CONNECT BY LEVEL <= 1000000;

COMMIT;

-- T_ORDER_DETAIL (500만건) - 대용량이므로 분할 처리
PROMPT 주문상세 데이터 생성... (500만건, 분할 처리)
INSERT /*+ APPEND */ INTO T_ORDER_DETAIL
SELECT 
    LEVEL                                      AS detail_id,
    MOD(LEVEL, 1000000) + 1                   AS order_id,
    MOD(LEVEL, 50000) + 1                     AS prod_id,
    ROUND(DBMS_RANDOM.VALUE(1, 10), 1)        AS qty,
    ROUND(DBMS_RANDOM.VALUE(1000, 50000), -1) AS unit_price,
    ROUND(DBMS_RANDOM.VALUE(1000, 500000), -2) AS amount,
    MOD(LEVEL, 50) + 1                        AS cat_id
FROM DUAL CONNECT BY LEVEL <= 5000000;

COMMIT;

-- T_LOG (200만건) 
PROMPT 시스템로그 데이터 생성... (200만건)
INSERT /*+ APPEND */ INTO T_LOG
SELECT 
    LEVEL                                    AS log_id,
    DATE '2024-01-01' + MOD(LEVEL, 815)     AS log_date,
    CASE MOD(LEVEL, 3)
        WHEN 0 THEN 'CPU'
        WHEN 1 THEN 'IO'  
        ELSE 'MEM' END                       AS category,
    ROUND(DBMS_RANDOM.VALUE(0, 100), 2)     AS value,
    'SESSION_' || MOD(LEVEL, 1000)          AS session_id,
    CASE WHEN MOD(LEVEL, 100) <= 5 THEN 'ERROR' ELSE 'NORMAL' END AS status
FROM DUAL CONNECT BY LEVEL <= 2000000;

COMMIT;

-- T_BOARD (50만건)
PROMPT 게시판 데이터 생성... (50만건)  
INSERT /*+ APPEND */ INTO T_BOARD
SELECT 
    LEVEL                                    AS board_id,
    'Title_' || LPAD(LEVEL, 6, '0')         AS title,
    'Content for board ' || LEVEL || '. ' ||
    'This is sample content with some text to make it realistic.' AS content,
    MOD(LEVEL, 100) + 1                     AS dept_id,
    CASE WHEN MOD(LEVEL, 20) = 1 THEN 'INACTIVE' ELSE 'ACTIVE' END AS status,
    DATE '2024-01-01' + MOD(LEVEL, 815)     AS created_date,
    MOD(LEVEL, 100000) + 1                  AS cust_id
FROM DUAL CONNECT BY LEVEL <= 500000;

COMMIT;

-- T_DAILY_SALES (300만건)
PROMPT 일별매출 데이터 생성... (300만건)
INSERT /*+ APPEND */ INTO T_DAILY_SALES
SELECT 
    DATE '2024-01-01' + MOD(LEVEL, 815)         AS sale_date,
    MOD(LEVEL, 1000) + 1                        AS store_id,
    MOD(LEVEL, 100000) + 1                      AS cust_id,
    CASE MOD(LEVEL, 3) 
        WHEN 0 THEN 'A' 
        WHEN 1 THEN 'B' 
        ELSE 'C' END                            AS sale_type,
    ROUND(DBMS_RANDOM.VALUE(1000, 100000), -2)  AS amount,
    'R' || LPAD(MOD(LEVEL, 20) + 1, 2, '0')    AS region_code,
    MOD(LEVEL, 50) + 1                          AS cat_id
FROM DUAL CONNECT BY LEVEL <= 3000000;

COMMIT;

PROMPT
PROMPT ========================================
PROMPT 4. 인덱스 생성
PROMPT ========================================

-- T_ORDER 인덱스 (case별 필요)
CREATE INDEX IDX_ORDER_01 ON T_ORDER (region_code, order_date, store_id);
CREATE INDEX IDX_ORDER_02 ON T_ORDER (cust_id, order_date);
CREATE INDEX IDX_ORDER_03 ON T_ORDER (order_date);
CREATE INDEX IDX_ORDER_04 ON T_ORDER (status);

-- T_ORDER_DETAIL 인덱스
CREATE INDEX IDX_ORDER_DETAIL_01 ON T_ORDER_DETAIL (order_id);
CREATE INDEX IDX_ORDER_DETAIL_02 ON T_ORDER_DETAIL (prod_id);
CREATE INDEX IDX_ORDER_DETAIL_03 ON T_ORDER_DETAIL (cat_id);

-- T_CUSTOMER 인덱스
CREATE INDEX IDX_CUSTOMER_01 ON T_CUSTOMER (region, grade);

-- T_LOG 인덱스
CREATE INDEX IDX_LOG_01 ON T_LOG (category, log_date);
CREATE INDEX IDX_LOG_02 ON T_LOG (log_date);

-- T_BOARD 인덱스
CREATE INDEX IDX_BOARD_01 ON T_BOARD (created_date);
CREATE INDEX IDX_BOARD_02 ON T_BOARD (dept_id);
CREATE INDEX IDX_BOARD_03 ON T_BOARD (status);

-- T_DAILY_SALES 인덱스
CREATE INDEX IDX_DAILY_SALES_01 ON T_DAILY_SALES (sale_date, store_id);
CREATE INDEX IDX_DAILY_SALES_02 ON T_DAILY_SALES (cust_id);
CREATE INDEX IDX_DAILY_SALES_03 ON T_DAILY_SALES (sale_type);

-- T_PRODUCT 인덱스
CREATE INDEX IDX_PRODUCT_01 ON T_PRODUCT (cat_id);

PROMPT
PROMPT ========================================
PROMPT 5. 통계 수집
PROMPT ========================================

BEGIN
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_CUSTOMER');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_ORDER');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_ORDER_DETAIL');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_PRODUCT');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_CATEGORY');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_CODE');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_STORE');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_LOG');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_BOARD');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_DEPT');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_STATUS');
    DBMS_STATS.GATHER_TABLE_STATS('APP_USER', 'T_DAILY_SALES');
END;
/

PROMPT
PROMPT ========================================
PROMPT 6. 데이터 건수 확인
PROMPT ========================================

SELECT '고객(T_CUSTOMER)' AS 테이블명, COUNT(*) AS 건수 FROM T_CUSTOMER
UNION ALL
SELECT '주문(T_ORDER)', COUNT(*) FROM T_ORDER
UNION ALL  
SELECT '주문상세(T_ORDER_DETAIL)', COUNT(*) FROM T_ORDER_DETAIL
UNION ALL
SELECT '상품(T_PRODUCT)', COUNT(*) FROM T_PRODUCT
UNION ALL
SELECT '카테고리(T_CATEGORY)', COUNT(*) FROM T_CATEGORY
UNION ALL
SELECT '공통코드(T_CODE)', COUNT(*) FROM T_CODE
UNION ALL
SELECT '매장(T_STORE)', COUNT(*) FROM T_STORE
UNION ALL
SELECT '시스템로그(T_LOG)', COUNT(*) FROM T_LOG
UNION ALL
SELECT '게시판(T_BOARD)', COUNT(*) FROM T_BOARD
UNION ALL
SELECT '부서(T_DEPT)', COUNT(*) FROM T_DEPT
UNION ALL
SELECT '상태코드(T_STATUS)', COUNT(*) FROM T_STATUS
UNION ALL
SELECT '일별매출(T_DAILY_SALES)', COUNT(*) FROM T_DAILY_SALES
ORDER BY 1;

PROMPT
PROMPT ========================================
PROMPT 공통 데이터 세트 구축 완료!
PROMPT ========================================
PROMPT 
PROMPT 이제 case_01.sql ~ case_16.sql을 실행하여
PROMPT 각 사례별 튜닝 기법을 학습하세요.
PROMPT