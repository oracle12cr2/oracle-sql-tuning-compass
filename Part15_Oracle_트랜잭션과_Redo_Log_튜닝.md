# Part 15. Oracle 트랜잭션과 Redo Log 튜닝

> 📖 출처: **Oracle SQL 실전 튜닝 나침반** — Part 15 (pp.539~557)
> 📝 정리: 유나 (2026-03-23)

---

## 목차

| Section | 제목 | 바로가기 |
|---------|------|---------|
| 01 | Transaction | [→](#section-01-transaction) |
| 02 | Redo & Undo | [→](#section-02-redo--undo) |
| 03 | 데이터 변경량과 Redo & Undo | [→](#section-03-데이터-변경량과-redo--undo) |
| 04 | 튜닝 실무 사례 | [→](#section-04-튜닝-실무-사례) |

---

## Section 01. Transaction

### Transaction이란?

- DBMS에서 데이터를 다루는 **논리적인 작업의 단위**
- INSERT, UPDATE, DELETE 등의 변경 작업을 하나의 트랜잭션으로 처리
- 트랜잭션 완료: **COMMIT** (반영) 또는 **ROLLBACK** (취소)

> **예시**: A계좌 → B계좌 이체 시, A에서 빼기 + B에서 더하기 = 2개 UPDATE가 하나의 트랜잭션

### ACID 성질

| 성질 | 설명 | 구현 메커니즘 |
|------|------|--------------|
| **원자성 (Atomicity)** | All or Nothing. 모두 완료되거나 모두 취소 | **Undo** |
| **일관성 (Consistency)** | DB는 항상 일관된 상태 유지 | **Undo** |
| **격리성 (Isolation)** | 다른 트랜잭션이 연산에 끼어들지 못함 | **Undo** |
| **영속성 (Durability)** | COMMIT된 트랜잭션은 시스템 장애 후에도 복구 가능 | **Redo** |

> 💡 **핵심**: Undo = 원자성 + 일관성 + 격리성, Redo = 영속성

### 체인지 벡터 (Change Vector)

- Redo와 Undo의 핵심 메커니즘
- 트랜잭션 처리 시 데이터 Block 변경을 설명하기 위한 구조
- **데이터는 두 번 기록**: Datafile + Redo Log File

**처리 순서:**
1. Undo 레코드에 대한 체인지 벡터 생성
2. 데이터 Block에 대한 체인지 벡터 생성
3. 체인지 벡터들을 하나의 **Redo 레코드로 결합** → **Log Buffer에 기록**
4. 데이터 Block 변경

---

### 트랜잭션 처리 — DML별 동작 원리

#### UPDATE 처리

> 📊 흐름: Buffer Cache에서 ROW 찾기 → Log Buffer에 Old/New Image 기록 → Undo에 Old Image 저장 → Data Block에 New Image UPDATE

1. Buffer Cache에서 해당 ROW를 찾음 (없으면 Datafile에서 Load → **ROW LOCK 설정**)
2. Old Image + New Image를 **Log Buffer에 기록**
3. Undo Block에 Old Image 기록
4. Buffer Cache의 Data Block에 New Image UPDATE

#### INSERT 처리

> 📊 흐름: Buffer Cache에 Load → Log Buffer에 위치정보+New Image 기록 → Undo에 위치정보 저장 → Free Block에 New Image 기록

1. Buffer Cache에 Load (**PK 존재 시 ROW LOCK** — 동일 PK INSERT 시 Lock 대기)
2. INSERT 데이터 위치정보 + New Image를 **Log Buffer에 기록**
3. 위치정보를 Undo 세그먼트에 기록 (Rollback 시 해당 위치 찾아서 DELETE)
4. Buffer Cache의 Free Block에 New Image 기록

#### DELETE 처리

> 📊 흐름: Datafile에서 대상 ROW를 Buffer Cache에 Load → Log Buffer에 기록 → Undo에 전체 Row 저장 → Buffer Cache에서 DELETE

1. Datafile에서 대상 ROW를 Buffer Cache에 Load → **ROW LOCK 설정**
2. DELETE 대상 ROW를 **Log Buffer에 기록**
3. DELETE 대상 ROW 전체를 Undo 세그먼트에 기록 (Rollback 시 INSERT 처리)
4. Buffer Cache의 Block에서 DELETE 처리

---

### 🔬 실습 1: 트랜잭션 상태 모니터링

```sql
-- 테이블 생성
CREATE TABLE ORDERS_REDO
AS SELECT * FROM ORDERS WHERE 1 = 0;

-- 10만건 INSERT (COMMIT 하지 않음)
INSERT INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;

-- 현재 트랜잭션 상태 확인
SELECT S.SID, S.SERIAL#, S.USERNAME, S.PROGRAM,
       T.START_TIME, S.STATUS,
       T.USED_UBLK,    -- 사용 중인 Undo Block 수
       T.USED_UREC     -- 사용 중인 Undo Record 수
  FROM V$SESSION S, V$TRANSACTION T
 WHERE S.TADDR = T.ADDR
   AND S.SID = (SELECT SID FROM V$MYSTAT WHERE ROWNUM <= 1)
 ORDER BY 5 DESC, 6 DESC, 1, 2, 3, 4;
```

> 💡 **USED_UBLK**: DML 규모가 클수록 Undo Block 사용량 증가. COMMIT 전 확인하면 트랜잭션 크기 파악 가능

---

## Section 02. Redo & Undo

### Online Redo Log Files

- Buffer Cache에 가해지는 **모든 변경 사항을 기록하는 파일**
- 건건이 Datafile에 기록하지 않고 **Append 방식으로 빠르게 기록**
- Buffer Block ↔ Datafile 동기화는 **DBWR이 Batch 방식으로 일괄 처리**

### Redo Log의 3가지 목적

| 목적 | 설명 |
|------|------|
| **1. Database 복구** | Media Fail(디스크 손상) 시 **Archived Redo Log** 이용 복구 |
| **2. Instance Recovery** | 비정상 종료 시 Online Redo Log로 복구 |
| **3. Fast Commit** | Random Write 대신 Append Write → 빠른 COMMIT |

#### Instance Recovery 과정

```
비정상 종료 → 재기동
  → Roll Forward: Online Redo Log 읽어 마지막 Checkpoint 이후 트랜잭션 수행
  → Rollback: Undo 데이터로 COMMIT 안 된 트랜잭션 모두 롤백
  → Database 완전 동기화 완료
```

#### Fast Commit 원리

- 트랜잭션 변경 → Datafile에 Random Write (느림)
- 대신 **Redo Log에 Append Write (빠름)** → DBWR이 나중에 Batch 처리
- Redo Log에 먼저 기록 → 빠르게 COMMIT 완료 = **Fast Commit**

### 트랜잭션과 Redo Log 기록 내용

| DML | Redo Log에 기록되는 내용 |
|-----|------------------------|
| **INSERT** | 추가된 레코드의 데이터 |
| **UPDATE** | 변경 컬럼의 이전 데이터 + 현재 UPDATE 데이터 |
| **DELETE** | 지워지는 Row의 **모든 컬럼** 데이터 |

---

### Undo 세그먼트

- 트랜잭션별로 Undo 세그먼트를 할당
- 변경 **이전(Before Image)** 을 Undo Record 단위로 기록
- **Undo Retention**: 트랜잭션 완료 후에도 지정 시간 동안 Undo 데이터 유지

### Undo 세그먼트의 3가지 목적

| 목적 | 설명 |
|------|------|
| **1. 트랜잭션 Rollback** | COMMIT 없이 ROLLBACK 시 Undo 데이터 사용 |
| **2. 트랜잭션 Recovery** | Instance Recovery 시 Roll Forward 완료 후, COMMIT 안 된 것 Rollback |
| **3. 읽기 일관성 (Read Consistency)** | SELECT 시점의 데이터를 보장하기 위해 Undo 사용 |

### 트랜잭션과 Undo 데이터

| DML | Undo에 저장되는 내용 | Rollback 시 동작 |
|-----|---------------------|------------------|
| **INSERT** | 추가된 레코드의 **ROWID** | 해당 ROWID 찾아서 DELETE |
| **UPDATE** | 변경 컬럼의 **Before Image** | Before Image를 다시 UPDATE |
| **DELETE** | 지워지는 Row **전체 컬럼의 Before Image** | Before Image를 다시 INSERT |

---

### 읽기 일관성 (Read Consistency) — SCN 기반

> 📊 **SCN 기반 읽기 일관성**: SELECT 시작 시점 SCN 결정 → Block SCN 비교 → Block SCN이 높으면 Undo에서 과거 버전 조회

#### SCN (System Change/Commit Number)

- **시스템 전체 공유 Global 변수**
- COMMIT 발생 시마다 **1씩 증가**
- Block 헤더에 마지막 변경 시점 SCN 관리

#### 읽기 일관성 동작

1. SELECT 실행 시 현재 시점의 **SCN 결정** (예: SCN 10023)
2. 데이터 Block 검색 시, Block의 SCN이 SELECT 시점 SCN보다 **높으면**
3. Undo 데이터를 이용해 SELECT 시점(SCN 10023)까지 **Rollback하여 Buffer Cache에 Loading**
4. → SELECT 시작 시점의 일관된 데이터 조회 보장

> 💡 **ORA-01555 (Snapshot too old)**: Undo 데이터가 이미 덮어씌워져 과거 시점 복원 불가 시 발생

### 🔬 실습 2: Redo 발생량 측정

```sql
-- Redo 발생량 측정 쿼리 (DML 전후로 실행하여 DELTA 계산)
SELECT B.NAME, A.VALUE
  FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC#
   AND B.NAME = 'redo size';

-- 예시: INSERT 전 redo size 확인 → INSERT 수행 → 다시 redo size 확인
-- DELTA = 후 값 - 전 값 = 해당 DML의 Redo 발생량 (BYTE)
```

---

## Section 03. 데이터 변경량과 Redo & Undo

### 실험 비교표 — Writing 방식별 Redo 발생량

#### 1. Conventional Writing (INDEX 없음)

| DML | 처리 건수 | Redo 발생량 |
|-----|----------|------------|
| INSERT | 100,000건 | 상대적 기준값 |
| INSERT | 200,000건 | ~2배 |
| DELETE | 300,000건 | DELETE가 가장 많음 |

> 💡 DELETE는 모든 컬럼의 Before Image를 Redo에 기록하므로 Redo 발생량이 가장 큼

#### 2. Conventional Writing (INDEX 존재)

```sql
CREATE INDEX IX_ORDERS_REDO_N3
ON ORDERS_REDO(EMPLOYEE_ID, ORDER_DATE);
```

- INDEX 세그먼트에도 DML이 처리되므로 **Redo/Undo 발생량 증가**
- INDEX가 많을수록 Redo 발생량 비례 증가

#### 3. Conventional Writing + NOLOGGING (INDEX 없음)

```sql
ALTER TABLE ORDERS_REDO NOLOGGING;
```

> ⚠️ **테이블 속성을 NOLOGGING으로 바꿔도 Buffer Cache를 경유하는 Conventional Write에서는 Redo/Undo가 그대로 발생!**

#### 4. Direct Path Writing + LOGGING (INDEX 없음)

```sql
ALTER TABLE ORDERS_REDO LOGGING;

INSERT /*+ APPEND */ INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
```

| DML | Redo 발생량 |
|-----|------------|
| INSERT (APPEND) | **최소** (데이터 건수 무관) |
| DELETE | 동일하게 발생 (DELETE는 Direct Path 불가) |

> 💡 `/*+ APPEND */` 힌트 = Buffer Cache 거치지 않고 Datafile로 Direct Path Write → INSERT 시 Redo/Undo **최소화**

#### 5. Direct Path Writing + NOLOGGING (INDEX 없음)

```sql
ALTER TABLE ORDERS_REDO NOLOGGING;

INSERT /*+ APPEND */ INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
```

- INSERT에 대해 Redo/Undo 발생량 **최소화** (LOGGING과 비슷)
- Direct Path에서는 NOLOGGING이든 LOGGING이든 INSERT Redo 최소

#### 6. Direct Path Writing (INDEX 존재)

```sql
CREATE INDEX IX_ORDERS_REDO_N3
ON ORDERS_REDO(EMPLOYEE_ID, ORDER_DATE) NOLOGGING;
```

- INDEX 존재 시 Direct Path Write에서도 **INDEX에 대한 Redo/Undo 발생**
- 다만 Conventional Write보다는 적게 발생

### 📊 핵심 비교 요약표

| 조건 | INSERT Redo | DELETE Redo | 비고 |
|------|------------|------------|------|
| Conventional + INDEX 없음 | 보통 | 높음 | 기본 모드 |
| Conventional + INDEX 있음 | **높음** | **더 높음** | INDEX DML로 추가 발생 |
| Conventional + NOLOGGING | 보통 | 높음 | ⚠️ **NOLOGGING 무시됨** |
| Direct Path + LOGGING | **최소** | 높음 | APPEND 힌트 |
| Direct Path + NOLOGGING | **최소** | 높음 | INSERT만 효과 |
| Direct Path + INDEX 있음 | 적음 | 높음 | INDEX 분은 발생 |

### 🔑 Redo/Undo 최소화 핵심 원칙

> **INDEX 개수 및 크기에 비례하여 Redo/Undo 발생**
> → 트랜잭션이 많은 **Hot 테이블**에는 INDEX를 최소화하고
> → 공통된 ACCESS 패턴에 따라 **최적의 INDEX를 설계**하는 것이 핵심

---

### 🔬 실습 3: Redo 발생량 비교 실험

```sql
-- 1) 준비: 테이블 생성
CREATE TABLE ORDERS_REDO
AS SELECT * FROM ORDERS WHERE 1 = 0;

-- 2) Redo 측정 함수 (세션별)
SELECT B.NAME, A.VALUE
  FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC#
   AND B.NAME = 'redo size';

-- 3) Conventional INSERT (10만건)
INSERT INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
-- → redo size DELTA 확인
COMMIT;

-- 4) TRUNCATE 후 Direct Path INSERT (10만건)
TRUNCATE TABLE ORDERS_REDO;

INSERT /*+ APPEND */ INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
-- → redo size DELTA 확인 (Conventional 대비 대폭 감소!)
COMMIT;

-- 5) INDEX 생성 후 다시 비교
CREATE INDEX IX_ORDERS_REDO_N3
ON ORDERS_REDO(EMPLOYEE_ID, ORDER_DATE);

TRUNCATE TABLE ORDERS_REDO;

INSERT /*+ APPEND */ INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
-- → INDEX 있을 때 Redo 증가량 확인
COMMIT;

-- 6) NOLOGGING + Direct Path
ALTER TABLE ORDERS_REDO NOLOGGING;
TRUNCATE TABLE ORDERS_REDO;

INSERT /*+ APPEND */ INTO ORDERS_REDO
SELECT * FROM ORDERS WHERE ROWNUM <= 100000;
-- → DELTA 확인
COMMIT;

ALTER TABLE ORDERS_REDO LOGGING;  -- 원복
```

---

## Section 04. 튜닝 실무 사례

### 문제 상황

- SOURCE DB의 기준 정보 테이블을 TARGET DB에 **1분 주기로 동기화**
- 방식: TARGET 테이블 **전체 DELETE → 전체 INSERT** (73,000건)
- 결과: **1분당 114MB Redo** 발생 (시간당 ~6.8GB)
- 전체 Redo 발생량의 **10% 이상** 점유

### 문제 분석

```
TARGET 테이블 전체 DELETE: ~65MB Redo
TARGET 테이블 전체 INSERT: ~49MB Redo
합계: ~114MB/분 = ~6.8GB/시간
```

→ 실제 SOURCE에서 변경/삭제되는 데이터는 **수십 건에 불과**

### 튜닝 방안: 변경분만 동기화

**GLOBAL TEMPORARY TABLE**을 이용하여 변경된 데이터만 처리:

```sql
-- 1) 중간 테이블 역할의 GTT 생성
CREATE GLOBAL TEMPORARY TABLE TEMP_TARGET_TABLE
AS SELECT * FROM TARGET_TABLE WHERE 1 = 0;

-- 2) SOURCE에서 변경/신규 데이터만 추출 (NOT EXISTS로 비교)
INSERT INTO TEMP_TARGET_TABLE
SELECT A.*
  FROM SOURCE_TABLE A
 WHERE NOT EXISTS (
    SELECT 1
      FROM TARGET_TABLE B
     WHERE A.OBJECT_ID = B.OBJECT_ID
       AND NVL(A.OWNER, '-')           = NVL(B.OWNER, '-')
       AND NVL(A.OBJECT_NAME, '-')     = NVL(B.OBJECT_NAME, '-')
       AND NVL(A.SUBOBJECT_NAME, '-')  = NVL(B.SUBOBJECT_NAME, '-')
       AND NVL(A.DATA_OBJECT_ID, 0)    = NVL(B.DATA_OBJECT_ID, 0)
       AND NVL(A.OBJECT_TYPE, '-')     = NVL(B.OBJECT_TYPE, '-')
       AND NVL(A.CREATED, SYSDATE)     = NVL(B.CREATED, SYSDATE)
       AND NVL(A.LAST_DDL_TIME, SYSDATE) = NVL(B.LAST_DDL_TIME, SYSDATE)
       AND NVL(A.STATUS, '-')          = NVL(B.STATUS, '-')
       -- ... (모든 컬럼 비교)
  );

-- 3) 변경된 데이터만 TARGET에서 삭제
DELETE TARGET_TABLE
 WHERE OBJECT_ID IN (SELECT OBJECT_ID FROM TEMP_TARGET_TABLE);

-- 4) 변경된 데이터만 TARGET에 적재
INSERT INTO TARGET_TABLE
SELECT * FROM TEMP_TARGET_TABLE;

COMMIT;
```

### 튜닝 결과

| 항목 | Before | After | 개선율 |
|------|--------|-------|--------|
| Redo 발생량/분 | 114MB | ~1MB | **99% 감소** |
| 처리 방식 | 전체 DELETE + INSERT | 변경분만 DELETE + INSERT | — |

### 🔬 실습 4: 동기화 튜닝 Before/After 비교

```sql
-- 환경 구성
-- SOURCE TABLE 생성
CREATE TABLE SOURCE_TABLE TABLESPACE APP_DATA
AS SELECT * FROM DBA_OBJECTS WHERE OBJECT_ID IS NOT NULL;

ALTER TABLE SOURCE_TABLE
ADD CONSTRAINT SOURCE_TABLE_PK PRIMARY KEY(OBJECT_ID)
USING INDEX TABLESPACE APP_DATA;

-- TARGET TABLE 생성
CREATE TABLE TARGET_TABLE TABLESPACE APP_DATA
AS SELECT * FROM SOURCE_TABLE;

ALTER TABLE TARGET_TABLE
ADD CONSTRAINT TARGET_TABLE_PK PRIMARY KEY(OBJECT_ID)
USING INDEX TABLESPACE APP_DATA;

-- GTT 생성
CREATE GLOBAL TEMPORARY TABLE TEMP_TARGET_TABLE
AS SELECT * FROM TARGET_TABLE WHERE 1 = 0;

-- Redo 측정 (BEFORE: 전체 DELETE + INSERT)
-- redo size 기록
SELECT B.NAME, A.VALUE FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC# AND B.NAME = 'redo size';

DELETE TARGET_TABLE;
INSERT INTO TARGET_TABLE SELECT * FROM SOURCE_TABLE;
COMMIT;

-- redo size 다시 확인 → DELTA = Before 방식 Redo 발생량
SELECT B.NAME, A.VALUE FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC# AND B.NAME = 'redo size';

-- Redo 측정 (AFTER: 변경분만 처리)
-- SOURCE에서 일부 데이터만 변경
UPDATE SOURCE_TABLE SET STATUS = 'CHANGED'
 WHERE ROWNUM <= 50;
COMMIT;

-- redo size 기록
SELECT B.NAME, A.VALUE FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC# AND B.NAME = 'redo size';

-- 변경분만 동기화
INSERT INTO TEMP_TARGET_TABLE
SELECT A.* FROM SOURCE_TABLE A
 WHERE NOT EXISTS (
    SELECT 1 FROM TARGET_TABLE B
     WHERE A.OBJECT_ID = B.OBJECT_ID
       AND NVL(A.STATUS, '-') = NVL(B.STATUS, '-')
       -- 비교할 주요 컬럼 추가
  );

DELETE TARGET_TABLE
 WHERE OBJECT_ID IN (SELECT OBJECT_ID FROM TEMP_TARGET_TABLE);

INSERT INTO TARGET_TABLE
SELECT * FROM TEMP_TARGET_TABLE;
COMMIT;

-- redo size 다시 확인 → DELTA = After 방식 Redo 발생량
-- → Before 대비 99% 감소 확인!
SELECT B.NAME, A.VALUE FROM V$MYSTAT A, V$STATNAME B
 WHERE A.STATISTIC# = B.STATISTIC# AND B.NAME = 'redo size';
```

> 💡 **참고**: Oracle to Oracle 환경이라면 **MATERIALIZED VIEW**를 이용하면 SOURCE-TARGET 간 동기화를 더 간단하게 구현 가능

---

## 핵심 체크리스트 ✅

1. **트랜잭션 ACID** — 원자성·일관성·격리성은 Undo, 영속성은 Redo로 구현
2. **데이터는 두 번 기록** — Datafile + Redo Log File (체인지 벡터 기반)
3. **Redo = 복구 + Fast Commit**, Undo = Rollback + Recovery + 읽기 일관성
4. **읽기 일관성** — SCN 비교하여 SELECT 시점의 데이터를 Undo에서 복원
5. **DELETE의 Redo가 가장 많음** — 모든 컬럼의 Before Image 기록
6. **NOLOGGING은 Conventional Write에서 무시됨** — Direct Path Write에서만 효과
7. **`/*+ APPEND */` = Direct Path Write** — Buffer Cache 거치지 않아 Redo 최소화
8. **INDEX가 많을수록 Redo/Undo 증가** — Hot 테이블은 INDEX 최소화
9. **전체 DELETE+INSERT 대신 변경분만 처리** — Redo 발생량 99% 감소 가능
10. **Redo 발생량 측정**: `V$MYSTAT`에서 `'redo size'` 확인 (DML 전후 DELTA)

---

## 💡 실무 적용 가이드

### 대량 데이터 적재 시 Redo 최소화 전략

```sql
-- 1단계: 테이블 NOLOGGING 전환
ALTER TABLE 대상_테이블 NOLOGGING;

-- 2단계: INDEX 비활성화 (Unusable)
ALTER INDEX IDX_대상_N1 UNUSABLE;
ALTER INDEX IDX_대상_N2 UNUSABLE;

-- 3단계: Direct Path INSERT
INSERT /*+ APPEND */ INTO 대상_테이블
SELECT * FROM 원본_테이블;
COMMIT;

-- 4단계: INDEX 재생성 (NOLOGGING + PARALLEL)
ALTER INDEX IDX_대상_N1 REBUILD NOLOGGING PARALLEL 4;
ALTER INDEX IDX_대상_N2 REBUILD NOLOGGING PARALLEL 4;

-- 5단계: 원복
ALTER TABLE 대상_테이블 LOGGING;
ALTER INDEX IDX_대상_N1 LOGGING NOPARALLEL;
ALTER INDEX IDX_대상_N2 LOGGING NOPARALLEL;
```

> ⚠️ **NOLOGGING 주의사항**: Data Guard 환경에서는 Standby DB에 전파되지 않으므로 반드시 **전환 후 백업** 필요
