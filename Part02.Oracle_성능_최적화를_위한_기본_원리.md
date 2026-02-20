# Part 02. Oracle 성능 최적화를 위한 기본 원리

## 1. 리터럴 SQL vs 바인드 변수

### 리터럴 SQL (Hard Parse 발생)

```sql
DECLARE
  V_SQL         VARCHAR2(1000);
  V_ORDER_ST_DT VARCHAR2(8);
  V_ORDER_ED_DT VARCHAR2(8);
  V_EMPLOYEE_ID VARCHAR2(5);
  V_ORDER_TOTAL NUMBER;
  V_PAS_TM      NUMBER;
  V_HDPAS_TM    NUMBER;
BEGIN
  -- SQL 실행전 파싱 관련 통계 값 저장
  SELECT MAX(DECODE(STAT_NAME, 'parse time elapsed', VALUE))
        ,MAX(DECODE(STAT_NAME, 'hard parse elapsed time', VALUE))
    INTO V_PAS_TM, V_HDPAS_TM
    FROM V$SYS_TIME_MODEL
   WHERE STAT_NAME IN ('parse time elapsed', 'hard parse elapsed time');

  -- 50000번 수행
  FOR I IN 1..50000 LOOP
    V_ORDER_ST_DT := LPAD(TRUNC(DBMS_RANDOM.VALUE(2007,2010)),4,'0')
                   || LPAD(TRUNC(DBMS_RANDOM.VALUE(1,12)),2,'0')
                   || LPAD(TRUNC(DBMS_RANDOM.VALUE(1,25)),2,'0');
    V_ORDER_ED_DT := TO_CHAR(TO_DATE(V_ORDER_ST_DT,'YYMMDD') + 1, 'YYYYMMDD');
    V_EMPLOYEE_ID := 'E' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0, 50000)),3,'0');

    -- 리터럴 SQL: 매번 다른 SQL → Hard Parse 발생
    V_SQL := ' SELECT /*+ BIND_TEST1 */ COUNT(*)
                 WHERE ORDER_DATE >= TO_DATE(''' || V_ORDER_ST_DT || ''',''YYYYMMDD'')
                   AND ORDER_DATE >= TO_DATE(''' || V_ORDER_ED_DT || ''',''YYYYMMDD'')
                   AND EMPLOYEE_ID = ''' || V_EMPLOYEE_ID || '''';

    EXECUTE IMMEDIATE V_SQL INTO V_ORDER_TOTAL;
  END LOOP;
END;
```

### 바인드 변수 사용 (Soft Parse)

```sql
DECLARE
  V_SQL         VARCHAR2(1000);
  V_ORDER_ST_DT VARCHAR2(8);
  V_ORDER_ED_DT VARCHAR2(8);
  V_EMPLOYEE_ID VARCHAR2(5);
  V_ORDER_TOTAL NUMBER;
  V_PAS_TM      NUMBER;
  V_HDPAS_TM    NUMBER;
BEGIN
  SELECT MAX(DECODE(STAT_NAME, 'parse time elapsed', VALUE))
        ,MAX(DECODE(STAT_NAME, 'hard parse elapsed time', VALUE))
    INTO V_PAS_TM, V_HDPAS_TM
    FROM V$SYS_TIME_MODEL
   WHERE STAT_NAME IN ('parse time elapsed', 'hard parse elapsed time');

  FOR I IN 1..50000 LOOP
    V_ORDER_ST_DT := LPAD(TRUNC(DBMS_RANDOM.VALUE(2007,2010)),4,'0')
                   || LPAD(TRUNC(DBMS_RANDOM.VALUE(1,12)),2,'0')
                   || LPAD(TRUNC(DBMS_RANDOM.VALUE(1,25)),2,'0');
    V_ORDER_ED_DT := TO_CHAR(TO_DATE(V_ORDER_ST_DT,'YYMMDD') + 1, 'YYYYMMDD');
    V_EMPLOYEE_ID := 'E' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0, 50000)),3,'0');

    -- 바인드 변수 사용: 동일 SQL → Soft Parse
    V_SQL := ' SELECT /*+ BIND_TEST2 */ COUNT(*)
                 WHERE ORDER_DATE >= TO_DATE(:V_ORDER_ST_DT, ''YYYYMMDD'')
                   AND ORDER_DATE >= TO_DATE(:V_ORDER_ED_DT, ''YYYYMMDD'')
                   AND EMPLOYEE_ID = :V_EMPLOYEE_ID';

    EXECUTE IMMEDIATE V_SQL INTO V_ORDER_TOTAL
      USING V_ORDER_ST_DT, V_ORDER_ED_DT, V_EMPLOYEE_ID;
  END LOOP;

  -- SQL 실행후 파싱 관련 통계 값 산출
  SELECT MAX(DECODE(STAT_NAME, 'parse time elapsed', VALUE)) - V_PAS_TM
        ,MAX(DECODE(STAT_NAME, 'hard parse elapsed time', VALUE)) - V_HDPAS_TM
    INTO V_PAS_TM, V_HDPAS_TM
    FROM V$SYS_TIME_MODEL
   WHERE STAT_NAME IN ('parse time elapsed', 'hard parse elapsed time');

  DBMS_OUTPUT.PUT_LINE(ROUND(V_PAS_TM   / 1000000, 5));
  DBMS_OUTPUT.PUT_LINE(ROUND(V_HDPAS_TM / 1000000, 5));
END;
/
```

> **핵심**: 리터럴 SQL은 매번 Hard Parse → CPU/Latch 낭비. 바인드 변수를 사용하면 Soft Parse로 재사용 가능.

---

## 2. IN 조건의 바인드 변수 처리

IN 리스트 개수가 달라지면 **별도의 SQL로 인식**되어 Hard Parse 발생.

```sql
-- 1개
SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, HIRE_DATE, SALARY
  FROM EMPLOYEES
 WHERE EMPLOYEE_ID IN (:V_EMPNO);

-- 2개
SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, HIRE_DATE, SALARY
  FROM EMPLOYEES
 WHERE EMPLOYEE_ID IN (:V_EMPNO1, :V_EMPNO2);

-- 3개
SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, HIRE_DATE, SALARY
  FROM EMPLOYEES
 WHERE EMPLOYEE_ID IN (:V_EMPNO1, :V_EMPNO2, :V_EMPNO3);

-- 4개
SELECT EMPLOYEE_ID, FIRST_NAME, LAST_NAME, HIRE_DATE, SALARY
  FROM EMPLOYEES
 WHERE EMPLOYEE_ID IN (:V_EMPNO1, :V_EMPNO2, :V_EMPNO3, :V_EMPNO4);
```

> **문제**: IN 리스트 개수별로 SQL이 달라짐 → Shared Pool 낭비

---

## 3. Dynamic SQL 통합 (DECODE 활용)

### Before: 조건별 개별 SQL (4개의 서로 다른 SQL)

```sql
-- 조건 2개
SELECT * FROM ORDERS
 WHERE ORDER_DATE >= :V_ST_DT
   AND ORDER_DATE <= :V_ED_DT;

-- 조건 3개
SELECT * FROM ORDERS
 WHERE ORDER_DATE >= :V_ST_DT
   AND ORDER_DATE <= :V_ED_DT
   AND ORDER_MODE = :V_ORD_MODE;

-- 조건 4개
SELECT * FROM ORDERS
 WHERE ORDER_DATE >= :V_ST_DT
   AND ORDER_DATE <= :V_ED_DT
   AND ORDER_MODE = :V_ORD_MODE
   AND CUSTOMER_ID = :V_CUST_ID;

-- 조건 5개
SELECT * FROM ORDERS
 WHERE ORDER_DATE >= :V_ST_DT
   AND ORDER_DATE <= :V_ED_DT
   AND ORDER_MODE = :V_ORD_MODE
   AND CUSTOMER_ID = :V_CUST_ID
   AND ORDER_STATUS = :V_ORD_ST;
```

### After: DECODE로 1개의 SQL로 통합

```sql
SELECT *
  FROM ORDERS
 WHERE ORDER_DATE >= :V_ST_DT
   AND ORDER_DATE <= :V_ED_DT
   AND ORDER_MODE    = DECODE(:V_ORD_MODE, NULL, ORDER_MODE,    :V_ORD_MODE)
   AND CUSTOMER_ID   = DECODE(:V_CUST_ID,  NULL, CUSTOMER_ID,   :V_CUST_ID)
   AND ORDER_STATUS  = DECODE(:V_ORD_STAT, NULL, ORDER_STATUS,  :V_ORD_STAT);
```

> **핵심**: 선택 조건이 NULL이면 `컬럼 = 컬럼` (항상 TRUE) → 조건 무시 효과

### UNION ALL로 선택적 인덱스 활용

```sql
-- CUSTOMER_ID가 NULL일 때와 아닐 때 분리 → 각각 최적 실행계획 사용
SELECT *
  FROM ORDERS
 WHERE ORDER_DATE >= :ST_DT
   AND ORDER_DATE <= :ED_DT
   AND ORDER_MODE    = DECODE(:V_ORD_MODE, NULL, ORDER_MODE,    :V_ORD_MODE)
   AND ORDER_STATUS  = DECODE(:V_ORD_STAT, NULL, ORDER_STATUS,  :V_ORD_STAT)
   AND :CUST_ID IS NULL
UNION ALL
SELECT *
  FROM ORDERS
 WHERE ORDER_DATE >= :ST_DT
   AND ORDER_DATE <= :ED_DT
   AND ORDER_MODE    = DECODE(:V_ORD_MODE, NULL, ORDER_MODE,    :V_ORD_MODE)
   AND CUSTOMER_ID   = :CUST_ID
   AND ORDER_STATUS  = DECODE(:V_ORD_STAT, NULL, ORDER_STATUS,  :V_ORD_STAT)
   AND :CUST_ID IS NOT NULL;
```

> **핵심**: CUSTOMER_ID 유무에 따라 다른 인덱스를 타도록 UNION ALL 분리

---

## 4. 사용자 정의 함수 vs 인라인 처리

### Anti-Pattern: 함수 호출 (Recursive Call 발생)

```sql
CREATE OR REPLACE FUNCTION SF_GET_WEEKEND(V_DATE DATE)
RETURN VARCHAR2
AS
  V_RTN_VALUE VARCHAR2(10);
BEGIN
  IF    TO_CHAR(V_DATE,'D') = '0' THEN V_RTN_VALUE := '일요일';
  ELSIF TO_CHAR(V_DATE,'D') = '1' THEN V_RTN_VALUE := '월요일';
  ELSIF TO_CHAR(V_DATE,'D') = '2' THEN V_RTN_VALUE := '화요일';
  ELSIF TO_CHAR(V_DATE,'D') = '3' THEN V_RTN_VALUE := '수요일';
  ELSIF TO_CHAR(V_DATE,'D') = '4' THEN V_RTN_VALUE := '목요일';
  ELSIF TO_CHAR(V_DATE,'D') = '5' THEN V_RTN_VALUE := '금요일';
  ELSIF TO_CHAR(V_DATE,'D') = '6' THEN V_RTN_VALUE := '토요일';
  END IF;
  RETURN V_RTN_VALUE;
END;

-- 함수 사용: 행마다 Recursive Call
SELECT SF_GET_WEEKEND(ORDER_DATE) AS WEEKAND
      ,COUNT(*) AS CNT
  FROM ORDERS
 GROUP BY SF_GET_WEEKEND(ORDER_DATE);
```

### Best Practice: CASE 문으로 인라인 처리

```sql
SELECT CASE WHEN TO_CHAR(ORDER_DATE,'D') = '0' THEN '일요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '1' THEN '월요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '2' THEN '화요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '3' THEN '수요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '4' THEN '목요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '5' THEN '금요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '6' THEN '토요일'
       END WEEKAND
      ,COUNT(*)
  FROM ORDERS
 GROUP BY CASE WHEN TO_CHAR(ORDER_DATE,'D') = '0' THEN '일요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '1' THEN '월요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '2' THEN '화요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '3' THEN '수요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '4' THEN '목요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '5' THEN '금요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '6' THEN '토요일'
          END;
```

### 더 나은 방법: 서브쿼리로 연산 최소화

```sql
SELECT CASE WHEN TO_CHAR(ORDER_DATE,'D') = '0' THEN '일요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '1' THEN '월요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '2' THEN '화요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '3' THEN '수요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '4' THEN '목요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '5' THEN '금요일'
            WHEN TO_CHAR(ORDER_DATE,'D') = '6' THEN '토요일'
       END WEEKAND
      ,SUM(CNT) CNT
  FROM (SELECT TRUNC(ORDER_DATE,'DD') AS ORDER_DATE
              ,COUNT(*) cnt
          FROM ORDERS
         GROUP BY TRUNC(ORDER_DATE,'DD'))
 GROUP BY CASE WHEN TO_CHAR(ORDER_DATE,'D') = '0' THEN '일요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '1' THEN '월요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '2' THEN '화요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '3' THEN '수요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '4' THEN '목요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '5' THEN '금요일'
               WHEN TO_CHAR(ORDER_DATE,'D') = '6' THEN '토요일'
          END;
```

> **핵심**: 먼저 날짜별 GROUP BY로 행 수를 줄인 뒤 요일 변환 → CASE 연산 횟수 대폭 감소

---

## 5. 함수 대신 조인 사용

### Anti-Pattern: 스칼라 함수로 조회

```sql
CREATE OR REPLACE FUNCTION SF_GET_CUST_JOB_NAME(V_CUSTOMER_ID VARCHAR2)
RETURN VARCHAR2
AS
  V_RTN_VALUE VARCHAR2(40);
BEGIN
  SELECT CUST_JOB_NAME
    INTO V_RTN_VALUE
    FROM CUSTOMERS
   WHERE CUSTOMER_ID = V_CUSTOMER_ID;
  RETURN V_RTN_VALUE;
END;

-- 함수 호출: 행마다 SELECT 발생
SELECT CUST_JOB_NAME, COUNT(*)
  FROM (SELECT SF_GET_CUST_JOB_NAME(CUSTOMER_ID) AS CUST_JOB_NAME
          FROM ORDERS A)
 GROUP BY CUST_JOB_NAME;
```

### 개선 1: 스칼라 서브쿼리 (함수보다 나음, 캐싱 효과)

```sql
SELECT CUST_JOB_NAME, COUNT(*)
  FROM (SELECT (SELECT CUST_JOB_NAME
                  FROM CUSTOMERS
                 WHERE CUSTOMER_ID = A.CUSTOMER_ID) CUST_JOB_NAME
          FROM ORDERS A)
 GROUP BY CUST_JOB_NAME;
```

### 개선 2: 조인 (가장 효율적)

```sql
SELECT B.CUST_JOB_NAME, COUNT(*)
  FROM ORDERS    A
      ,CUSTOMERS B
 WHERE A.CUSTOMER_ID = B.CUSTOMER_ID
 GROUP BY B.CUST_JOB_NAME;
```

> **핵심**: 함수 → 스칼라 서브쿼리 → 조인 순으로 성능 향상. 조인이 가장 빠름.

---

## 6. 페이징 처리에서의 함수 호출 최적화

```sql
-- 페이징 결과(10건)에만 함수 호출 → Recursive Call 최소화
SELECT RN, ORDER_ID, ORDER_DATE, CUSTOMER_ID
      ,SF_GET_CUST_JOB_NAME(CUSTOMER_ID) AS CUST_JOB_NAME
      ,ORDER_TOTAL
  FROM (SELECT ROWNUM RN
              ,ORDER_ID, ORDER_DATE, CUSTOMER_ID, ORDER_TOTAL
          FROM (SELECT ORDER_ID, ORDER_DATE, CUSTOMER_ID, ORDER_TOTAL
                  FROM ORDERS
                 WHERE ORDER_DATE >= TO_DATE('20090805','YYYYMMDD')
                   AND ORDER_DATE <= TO_DATE('20090806','YYYYMMDD')
                 ORDER BY ORDER_DATE DESC)
         WHERE ROWNUM <= 10)
 WHERE RN >= 1;
```

> **핵심**: 함수를 꼭 써야 한다면, 최종 결과(페이징 후)에서만 호출하여 Call 횟수 최소화

---

## 7. UNPIVOT 패턴 (CONNECT BY LEVEL)

```sql
-- 컬럼 → 행 변환: 1행의 4개 결제수단을 4행으로 UNPIVOT
INSERT INTO TB_TARGET
SELECT ORDER_YM
      ,CUSTOMER_ID
      ,CASE WHEN RCNT = 1 THEN 'CARD'
            WHEN RCNT = 2 THEN 'CASH'
            WHEN RCNT = 3 THEN 'PHONE'
            WHEN RCNT = 4 THEN 'BK'
       END "결재방법"
      ,CASE WHEN RCNT = 1 THEN CARD_AMT
            WHEN RCNT = 2 THEN CASH_AMT
            WHEN RCNT = 3 THEN PHONE_AMT
            WHEN RCNT = 4 THEN BK_AMT
       END AMT
  FROM TB_SOURCE
      ,(SELECT LEVEL RCNT FROM DUAL CONNECT BY LEVEL <= 4);
COMMIT;
```

> **핵심**: `CONNECT BY LEVEL`로 복제 행을 만들어 CROSS JOIN → CASE로 UNPIVOT 처리
