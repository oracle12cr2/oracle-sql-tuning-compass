# Part 19. 튜닝 실무 사례

> 📖 출처: **Oracle SQL 실전 튜닝 나침반** — Part 19 튜닝 실무 사례 (pp.805~871)
> 📝 정리: 루나 (2026-03-16)

---

## 개요

지금까지 학습한 튜닝 원리와 패턴이 실무에서 어떻게 적용되는지 16개의 실전 사례를 통해 확인한다. 매우 복잡하고 긴 SQL도 하나씩 풀어내면 **대부분 기본 해법은 동일**하다.

이번 단원에서 정리한 SQL들은 필자가 실무에서 튜닝했던 사례를 이용한 것이다. 기본 원리와 패턴만 이해하고 있다면 어렵지 않게 접근할 수 있을 것이다.

---

## 목차

| Section | 관련 단원 | 핵심 튜닝 기법 | 개선 효과 |
|---------|----------|--------------|----------|
| [01](#section-01-index-skip-scan-활용) | INDEX ACCESS 패턴 | INDEX SKIP SCAN | Buffers 101K → 33 |
| [02](#section-02-적절한-index-선택) | INDEX ACCESS 패턴 | 적절한 INDEX 힌트 지정 | Buffers 357K → 20 |
| [03](#section-03-nl-join--hash-join-변경) | JOIN | NL JOIN → HASH JOIN 변경 | 실행시간 67초 → 6초 |
| [04](#section-04-jppd-활용) | JOIN (JPPD) | JPPD (JOIN PREDICATE PUSH DOWN) | I/O 2,129K → 1,155 |
| [05](#section-05-join--스칼라-서브쿼리-변환) | 서브쿼리 | JOIN → 스칼라 서브쿼리 변환 | I/O 5,256 → 2,239 |
| [06](#section-06-exists--join-순서-변경) | JOIN, 서브쿼리, 반복 ACCESS | EXISTS + JOIN 순서 변경 | I/O 1,809K → 7,668 |
| [07](#section-07-실행-계획-분리) | 실행 계획 분리 | UNION ALL로 실행 계획 분리 | FULL SCAN 제거 |
| [08](#section-08-join-순서-변경--스칼라-서브쿼리) | JOIN, 실행 계획 분리 | JOIN 순서 변경 + 스칼라 서브쿼리 | I/O 대폭 감소 |
| [09](#section-09-jppd로-인라인뷰-침투) | 서브쿼리, PGA 튜닝 | JPPD + NL JOIN 적용 | PGA 32M 제거 |
| [10](#section-10-window-함수--exists) | JOIN, 서브쿼리, PGA | WINDOW 함수 + EXISTS | 반복 ACCESS 제거 |
| [11](#section-11-union--case-when-통합) | 동일 데이터 반복 ACCESS | UNION → CASE WHEN 통합 | 반복 SCAN 제거 |
| [12](#section-12-index-full-scanminmax-유도) | INDEX ACCESS, 페이징 | INDEX FULL SCAN(MIN/MAX) 유도 | I/O 대폭 감소 |
| [13](#section-13-페이징-후-join--스칼라-서브쿼리) | 페이징 처리, 서브쿼리 | 페이징 후 JOIN + 스칼라 서브쿼리 | I/O 802K → 수십 |
| [14](#section-14-join-순서방법-최적화) | JOIN | JOIN 순서/방법 최적화 | 불필요 필터링 제거 |
| [15](#section-15-jppd로-인라인뷰-group-by-제거) | JOIN (JPPD) | JPPD로 인라인뷰 침투 | 전체 GROUP BY 제거 |
| [16](#section-16-join-순서방법--서브쿼리-최적화) | 서브쿼리 | JOIN 순서/방법 + 서브쿼리 최적화 | I/O 대폭 감소 |

---

## Section 01. INDEX SKIP SCAN 활용

**관련 단원**: INDEX ACCESS 패턴

### 테이블 정보
- **외화수표일별 테이블 INDEX 현황**
  - `IX_외화수표일별_N1`: [중앙회조합구분코드, 매입추심구분코드, 거래일자, 사무소코드]

### 바인드 변수
```sql
:B0 -> '20120403'
```

### 원본 SQL
```sql
SELECT 
    T3.사무소코드, T3.외화수표거래번호, T3.대표고객번호,
    T3.고객번호, T3.계리세목코드, T2.신규일자,
    T2.입금예정일자, T3.통화코드,
    T3.외화잔액, T2.환율변동회차, T2.외환상태코드
FROM 외화수표매입 T2,
     (SELECT 
          T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
          T1.고객번호, T1.계리세목코드, T1.통화코드,
          SUM(T1.외화잔액) 외화잔액
      FROM 외화수표일별 T1
      WHERE T1.중앙회조합구분코드 = '1'
        AND T1.거래일자 LIKE (:B0 || '%')
      GROUP BY T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
               T1.고객번호, T1.계리세목코드, T1.통화코드) T3
WHERE T2.외화수표거래번호 = T3.외화수표거래번호;
```

### 원본 실행계획
```
Id | Operation                    | Name                | Starts | A-Rows | A-Time      | Buffers
---|------------------------------|---------------------|--------|--------|-------------|--------
 1 | NESTED LOOPS                 |                     |      1 |    524 | 00:02:18.08 |  103K
 2 |  VIEW                        |                     |      1 |    524 | 00:02:17.52 |  102K
 3 |   HASH GROUP BY              |                     |      1 |    524 | 00:02:17.52 |  102K
 4 |    TABLE ACCESS BY INDEX ROWID| 외화수표일별          |      1 |   2913 | 00:02:17.48 |  102K
*5 |     INDEX RANGE SCAN         | IX_외화수표일별_N1    |      1 |   2913 | 00:02:17.12 |  101K
 6 |  TABLE ACCESS BY INDEX ROWID | 외화수표매입          |    524 |    524 | 00:00:00.55 |   1055
*7 |   INDEX UNIQUE SCAN          | PK_외화수표매입       |    524 |    524 | 00:00:00.48 |   1055
```

### 문제점
`IX_외화수표일별_N1` INDEX 컬럼은 [중앙회조합구분코드, 매입추심구분코드, 거래일자, 사무소코드]로 되어 있으나 조회 조건은 중앙회조합구분코드= AND 거래일자 LIKE로 들어오면서 **중간 조건인 매입추심구분코드가 누락**되어 중앙회조합구분코드 이후 조건은 필터 조건으로만 참여한다.

즉, 중앙회조합구분코드='1' 조건에 해당하는 모든 데이터를 가져와서 거래일자 LIKE (:B0 || '%') 조건에 해당하는 데이터만 필터링하기 때문에 **넓은 범위의 INDEX Block을 SCAN**한다(2,913건을 SCAN하면서 101K Block을 ACCESS하고 있다).

### 튜닝 내용
실제로 [매입추심구분코드] 컬럼의 DISTINCT한 값의 종류는 **2개**이다. 이럴 때 **INDEX SKIP SCAN**을 이용하면 [매입추심구분코드] 뒤의 INDEX 컬럼인 거래일자 LIKE 조건이 ACCESS 조건처럼 사용되어 INDEX SCAN 범위를 크게 줄여줄 수 있다.

### 튜닝 후 SQL
```sql
SELECT 
    T3.사무소코드, T3.외화수표거래번호, T3.대표고객번호,
    T3.고객번호, T3.계리세목코드, T2.신규일자,
    T2.입금예정일자, T3.통화코드,
    T3.외화잔액, T2.환율변동회차, T2.외환상태코드
FROM 외화수표매입 T2,
     (SELECT /*+ INDEX_SS(T1 IX_외화수표일별_N1) */
          T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
          T1.고객번호, T1.계리세목코드, T1.통화코드,
          SUM(T1.외화잔액) 외화잔액
      FROM 외화수표일별 T1
      WHERE T1.중앙회조합구분코드 = '1'
        AND T1.거래일자 LIKE (:B0 || '%')
      GROUP BY T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
               T1.고객번호, T1.계리세목코드, T1.통화코드) T3
WHERE T2.외화수표거래번호 = T3.외화수표거래번호;
```

### 튜닝 후 실행계획
```
Id | Operation                    | Name                | Starts | A-Rows | A-Time      | Buffers
---|------------------------------|---------------------|--------|--------|-------------|--------
 1 | NESTED LOOPS                 |                     |      1 |    524 | 00:00:00.62 |   2590
 2 |  VIEW                        |                     |      1 |    524 | 00:00:00.61 |   1011
 3 |   HASH GROUP BY              |                     |      1 |    524 | 00:00:00.61 |   1011
 4 |    TABLE ACCESS BY INDEX ROWID| 외화수표일별          |      1 |    524 | 00:00:00.61 |   1011
*5 |     INDEX SKIP SCAN          | IX_외화수표일별_N1    |      1 |    524 | 00:00:00.60 |     33
 6 |  TABLE ACCESS BY INDEX ROWID | 외화수표매입          |    524 |    524 | 00:00:00.01 |   1579
*7 |   INDEX UNIQUE SCAN          | PK_외화수표매입       |    524 |    524 | 00:00:00.01 |   1055
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| INDEX Buffers | 101K | **33** | **99.97%** |
| 실행 시간 | 2분 17초 | **0.62초** | **99.5%** |

---

## Section 02. 적절한 INDEX 선택

**관련 단원**: INDEX ACCESS 패턴

### 테이블 정보
- **카드환불내역 테이블 INDEX 현황**
  - `카드환불내역_PK`: 기본키
  - `카드환불내역_IX1`: 작업일자 관련 INDEX

### 원본 SQL
```sql
SELECT *
FROM 카드환불내역
WHERE 작업일자 BETWEEN :시작일 AND :종료일
  AND [기타 조건들...]
ORDER BY [정렬 조건];
```

### 문제점
조회 조건 `작업일자`에 적합한 INDEX(`카드환불내역_IX1`)가 있으나, 옵티마이저가 ORDER BY를 피하기 위해 **부적절한 PK INDEX FULL SCAN** 선택 → 417K건 전체 SCAN 후 필터링

### 튜닝 후 SQL
```sql
SELECT /*+ INDEX(카드환불내역 카드환불내역_IX1) */ *
FROM 카드환불내역
WHERE 작업일자 BETWEEN :시작일 AND :종료일
  AND [기타 조건들...]
ORDER BY [정렬 조건];
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| Buffers | 357K | **20** | **99.99%** |
| 실행 시간 | 33.77초 | **0.06초** | **99.8%** |

> 💡 A-Rows 427건, Buffers 20 → **CLUSTERING FACTOR 양호**

---

## Section 03. NL JOIN → HASH JOIN 변경

**관련 단원**: JOIN

### 테이블 정보
- **접수처리기본**: 42만 건
- **신청기본**: 약 4MB
- **여신고객기본**: 약 192MB
- **개인사업자내역**: 소형 테이블

### 원본 SQL
```sql
SELECT 
    T1.여신심사접수번호, T1.여신심사접수일련번호,
    T1.여신신청일자, T1.처리일자, T1.실명번호,
    T2.소매여부, T2.신용조사기업식별번호
FROM (
    SELECT 
        A.여신심사접수번호, A.여신심사접수일련번호,
        A.여신신청일자, A.처리일자, C.실명번호,
        NVL(B.투자금융유형코드, 0) 투자금융유형코드
    FROM 접수처리기본 A, 신청기본 B, 여신고객기본 C
    WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
      AND A.기업여신상담번호 = B.기업여신상담번호(+)
      AND A.여신심사접수번호 = C.여신심사접수번호
      AND A.여신심사접수일련번호 = C.여신심사접수일련번호
      AND A.처리일자 <= :B0
      AND A.중앙회조합구분코드 IN ('1', '5')
) T1, 개인사업자내역 T2
WHERE T1.실명번호 = T2.신용조사기업식별번호(+);
```

### 원본 실행계획
```
Id | Operation                    | Name           | Starts | A-Rows | A-Time      | Buffers
---|------------------------------|----------------|--------|--------|-------------|--------
 1 | NESTED LOOPS                 |                |      1 |   421K | 01:07:86    |   2095K
 2 |  NESTED LOOPS                |                |      1 |   421K | 01:00:43    |   1268K
 3 |   NESTED LOOPS               |                |      1 |   421K | 00:53:03    |    441K
 4 |    TABLE ACCESS FULL         | 접수처리기본     |      1 |   421K | 00:01:26    |   23620
 5 |    TABLE ACCESS BY INDEX ROWID| 여신고객기본     |   421K |   421K | 00:51:37    |    418K
 6 |     INDEX UNIQUE SCAN        | 여신고객기본_PK  |   421K |   421K | 00:07:40    |    847K
 7 |   TABLE ACCESS BY INDEX ROWID | 개인사업자내역   |   421K |  54077 | 00:03:63    |    479K
 8 |    INDEX UNIQUE SCAN         | 개인사업자내역_PK|   421K |  54077 | 00:02:28    |    425K
```

### 문제점
선행 테이블인 [접수처리기본]에서 42만 건 이상의 많은 건수가 후행 테이블들과 **41만 번 이상 NL JOIN**이 되면서(Starts 통계) 많은 Random Single Block I/O로 인해 성능이 저하되었다.

### 튜닝 내용
각 테이블들의 사이즈 현황을 보면 사이즈가 매우 작은 편이다. 많은 건수가 NL JOIN 되면서 Single Block I/O 부하가 심하고 JOIN 되는 테이블 사이즈가 작으므로 **FULL TABLE SCAN + HASH JOIN**으로 SQL이 실행되도록 힌트를 기술한다.

### 튜닝 후 SQL
```sql
SELECT /*+ USE_HASH(T1 T2) */
    T1.여신심사접수번호, T1.여신심사접수일련번호,
    T1.여신신청일자, T1.처리일자, T1.실명번호,
    T2.소매여부, T2.신용조사기업식별번호
FROM (
    SELECT /*+ USE_HASH(A B C) */
        A.여신심사접수번호, A.여신심사접수일련번호,
        A.여신신청일자, A.처리일자, C.실명번호,
        NVL(B.투자금융유형코드, 0) 투자금융유형코드
    FROM 접수처리기본 A, 신청기본 B, 여신고객기본 C
    WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
      AND A.기업여신상담번호 = B.기업여신상담번호(+)
      AND A.여신심사접수번호 = C.여신심사접수번호
      AND A.여신심사접수일련번호 = C.여신심사접수일련번호
      AND A.처리일자 <= :B0
      AND A.중앙회조합구분코드 IN ('1', '5')
) T1, 개인사업자내역 T2
WHERE T1.실명번호 = T2.신용조사기업식별번호(+);
```

### 튜닝 후 실행계획
```
Id | Operation                    | Name           | Starts | A-Rows | A-Time      | Buffers | Used-Mem
---|------------------------------|----------------|--------|--------|-------------|---------|----------
 1 | HASH JOIN RIGHT OUTER        |                |      1 |   421K | 00:00:06.17 |  51736  | 1517K(0)
 2 |  TABLE ACCESS FULL           | 개인사업자내역   |      1 |   8686 | 00:00:00.01 |     92  |
 3 |  HASH JOIN RIGHT OUTER       |                |      1 |   421K | 00:00:05.30 |  51644  | 3131K(0)
 4 |   TABLE ACCESS FULL          | 신청기본        |      1 |   1561 | 00:00:00.01 |    412  |
 5 |   HASH JOIN                  |                |      1 |   421K | 00:00:04.45 |  51232  | 35M(0)
 6 |    TABLE ACCESS FULL         | 접수처리기본     |      1 |   421K | 00:01:26    |  23620  |
 7 |    TABLE ACCESS FULL         | 여신고객기본     |      1 |   570K | 00:00:57    |  27612  |
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| Buffers | 2,095K | **51,736** | **97.5%** |
| 실행 시간 | 1분 7초 | **6.17초** | **90.8%** |

> ⚠️ JOIN 테이블이 수 GB 이상이면 상황 고려 필요

---

## Section 04. JPPD 활용

**관련 단원**: JOIN (JPPD)

### 테이블 정보
- **V_처리내역 VIEW**: UNION ALL VIEW (SCHEMA1.처리내역 UNION ALL SCHEMA2.처리내역)
- **메타기본**: 메타 정보
- **BPM_이력전송**: 이력 데이터

### 원본 SQL
```sql
SELECT 
    A.인덱스ID, B.상태,
    TO_CHAR(B.완료시간, 'YYYYMMDDHH24MISS') 완료시간
FROM 메타기본 A,
     (SELECT 
          B.고객아이디, B.처리아이디, B.상태,
          B.완료시간, B.설명
      FROM (
          SELECT 처리아이디
          FROM BPM_이력전송
          WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                            AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
          GROUP BY 처리아이디
      ) A, V_처리내역 B
      WHERE A.처리아이디 = B.처리아이디
        AND B.설명 LIKE 'TLN%'
     ) B
WHERE A.인덱스ID = B.고객아이디;
```

### 문제점
인라인뷰 결과 108건이 UNION ALL VIEW로 **침투하지 못함** → VIEW 전체 830만 건 SCAN 후 HASH JOIN

### 튜닝 후 SQL
```sql
SELECT /*+ USE_NL(A B) */
    A.인덱스ID, B.상태,
    TO_CHAR(B.완료시간, 'YYYYMMDDHH24MISS') 완료시간
FROM 메타기본 A,
     (SELECT /*+ NO_MERGE USE_NL(A B) */
          B.고객아이디, B.처리아이디, B.상태,
          B.완료시간, B.설명
      FROM (
          SELECT 처리아이디
          FROM BPM_이력전송
          WHERE 변경시간 BETWEEN TO_DATE(:JobDate, 'YYYYMMDD')
                            AND TO_DATE(:JobDate, 'YYYYMMDD') + 1
          GROUP BY 처리아이디
      ) A, V_처리내역 B
      WHERE A.처리아이디 = B.처리아이디
        AND B.설명 LIKE 'TLN%'
     ) B
WHERE A.인덱스ID = B.고객아이디;
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| Buffers | 2,129K | **1,155** | **99.95%** |
| 실행 시간 | 5분 26초 | **0.02초** | **99.99%** |
| PGA | 1,217K | **0** | **100%** |

> 💡 실행 계획에 **UNION ALL PUSHED PREDICATE** Operation 확인

---

## Section 05. JOIN → 스칼라 서브쿼리 변환

**관련 단원**: 서브쿼리

### 테이블 정보
- **청구서내역**: 메인 테이블
- **단순통합코드**: 24MB (코드성 테이블)
- **카드기본**: 카드 정보
- **고객기본**: 3829MB (대용량 테이블)

### 바인드 변수
```sql
:nx_회원사회원번호 -> '112000697556001'
:nx_rowid -> 'AAAn...AAJ'
```

### 원본 SQL
```sql
SELECT 
    E.RID, E.회원사회원번호, E.카드번호,
    E.출금금액, E.은행코드, E.결제계좌,
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
```

### 문제점
[단순통합코드] 테이블과의 [A.결제신은행코드 = B.단순코드(+)] JOIN은 INPUT값의 DISTINCT한 값의 종류가 적다. 또한 [고객기본] 테이블은 3829MB로 사이즈가 크지만, [A.카드고객번호 = :카드고객번호]와 같이 조건 값이 들어오기 때문에 JOIN절인 [C.소지자카드고객번호 = D.카드고객번호(+)]에서의 값의 종류는 매우 적을 것이다.

### 튜닝 내용
[단순통합코드내역] 테이블과 [고객기본] 테이블과의 JOIN이 **UNIQUE KEY OUTER JOIN**이고 JOIN되는 값의 종류가 매우 적기 때문에 **스칼라 서브쿼리로 변경**한다. 그러면 스칼라 서브쿼리 캐싱 효과로 I/O가 크게 줄어들게 된다.

### 튜닝 후 SQL
```sql
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
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| Buffers | 5,256 | **2,239** | **57.4%** |
| 스칼라 서브쿼리 Starts | — | **1** (캐싱) |

> ⚠️ 값 종류가 **많으면** 캐싱 효과 없음 → 반대로 스칼라 서브쿼리를 FROM절 JOIN으로 변경해야 할 수도 있음

---

## Section 06. EXISTS + JOIN 순서 변경

**관련 단원**: JOIN, 서브쿼리, 동일 데이터 반복 ACCESS 튜닝

### 문제점
1. 거래내역 테이블을 MAX() 서브쿼리로 **2번 반복 SCAN**
2. JOIN 순서 비효율 → 530K건이 JOIN 후 90% 버려짐
3. 소형 테이블이 NL JOIN 후행으로 53만 번 JOIN

### 튜닝 내용
- MAX() 서브쿼리를 **EXISTS**로 변환
- JOIN 순서 최적화
- 소형 테이블 HASH JOIN

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| Buffers | 1,809K | **7,668** | **99.6%** |
| 실행 시간 | 2분 9초 | **대폭 개선** |

---

## Section 07. 실행 계획 분리

**관련 단원**: 실행 계획 분리

### 문제점
OPTIONAL 바인드 변수(NULL 가능)로 인해 옵티마이저가 **최적 INDEX를 선택하지 못함** → FULL TABLE SCAN

### 튜닝 내용
바인드 변수 NULL 여부에 따라 **UNION ALL로 실행 계획 분리**

```sql
SELECT ...
FROM 경영체등록내역 A, 경영체종사원등록내역 B
WHERE A.삭제여부 = '0' AND B.삭제여부='0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND (:B4 IS NOT NULL AND A.경영체등록번호=:B4)

UNION ALL

SELECT ...
FROM 경영체등록내역 A, 경영체종사원등록내역 B
WHERE A.삭제여부 = '0' AND B.삭제여부='0'
  AND A.경영체등록번호 = B.경영체등록번호
  AND ((:B1 IS NOT NULL OR :B2 IS NOT NULL) 
       AND A.경영주실명번호 IN(:B1, :B2))
```

> 💡 DECODE/NVL로 OPTIONAL 처리 시 INDEX 사용 불가 → 실행 계획 분리가 답

---

## Section 08. JOIN 순서 변경 + 스칼라 서브쿼리

**관련 단원**: JOIN, 실행 계획 분리

### 테이블 정보
- **취급상품기본**: 메인 테이블
- **상품기본**: 상품 정보 (상품기본_IX1: 상품명, 상품코드)
- **취급상품매출단가**: 단가 정보

### 바인드 변수
```sql
:사업장코드 -> '8808990167909'
:상품코드 -> NULL
:상품명 -> '고추'
:매출단가유형코드 -> '01'
```

### 문제점
선행 테이블 결과 36,150건이 후행과 NL JOIN → 상품명 LIKE 조건에 의해 19건만 남고 대부분 필터링

### 튜닝 내용
JOIN 순서 최적화 + 필터링 조건을 먼저 적용

---

## Section 09. JPPD로 인라인뷰 침투

**관련 단원**: 서브쿼리, PGA 튜닝

### 문제점
[게시판 관리], [게시판]의 JOIN된 결과 건수가 **1건**으로 매우 적다. 이 결과 건수가 후행 인라인뷰로 침투되지 못했다(JPPD발생 안함). 그래서 인라인뷰가 별도로 실행되어 UNION으로 인한 SORT 발생으로 **PGA가 32M** 사용되고 있다.

### 튜닝 내용
COALESCE 함수를 이용해서 스칼라 서브쿼리로 변경. COALESCE 함수를 사용하게 되면 NULL이 아닌 최초 INPUT 값을 반환한다.

```sql
SELECT COALESCE(NULL, NULL, 'A') FROM DUAL;  -- => 'A'
SELECT COALESCE('B', NULL, 'A') FROM DUAL;   -- => 'B' 
SELECT COALESCE(NULL, 'C', 'A') FROM DUAL;   -- => 'C'
```

### 튜닝 후 SQL
```sql
SELECT 
    게시판ID, 게시물번호, 제목, 내용,
    수정구분, 수정자, 수정일시, 코드ID,
    코드명, 상세코드ID, 상세코드명,
    TRIM(SUBSTRB(USR_VALUE, 1, 30)) 사용자명,
    (SELECT D.사무소코드 
     FROM GCCOM_임직원정보 D 
     WHERE SUBSTRB(USR_VALUE, 31) = D.사무소코드) 사무소명
FROM (
    SELECT 
        A.게시판ID, A.게시물번호, A.제목, A.내용,
        A.수정구분, A.수정자, A.수정일시, B.코드ID,
        B.코드명, B.상세코드ID, B.상세코드명,
        COALESCE(
            (SELECT RPAD(상담사이름, 30, ' ') || 사무소코드
             FROM 상담사인사원장 B
             WHERE B.사용구분 = '1' AND A.입력자 = B.개인번호),
            (SELECT RPAD(성명, 30, ' ') || 사무소코드
             FROM 사용인 B  
             WHERE B.사용구분 = '1' AND A.입력자 = B.사용인채널코드),
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
      AND A.게시판ID = :1
      AND A.게시물번호 = :2
) A;
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 |
|------|---------|---------|
| PGA 사용 | 32M | **0** |

---

## Section 10. WINDOW 함수 + EXISTS

**관련 단원**: JOIN, 서브쿼리, PGA 튜닝

### 문제점
SELECT절 참조 컬럼만 다르게 하여 동일 테이블을 UNION 위아래에서 **반복 ACCESS**

### 튜닝 내용
- WINDOW 함수(분석 함수)로 통합 
- EXISTS로 중복 제거
- WITH절로 동일 구간 정의

### 튜닝 후 구조
```sql
WITH 공통데이터 AS (
    /*+ MATERIALIZE */
    SELECT ... FROM 동일접근테이블 WHERE 공통조건
),
분석데이터 AS (
    SELECT ..., 
           RANK() OVER (PARTITION BY ... ORDER BY ...) rk
    FROM 공통데이터
)
SELECT ... FROM 분석데이터 WHERE rk = 1;
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| I/O | 9,569K | **2,019K** | **78.9%** |

---

## Section 11. UNION → CASE WHEN 통합

**관련 단원**: 동일 데이터 반복 ACCESS 튜닝

### 문제점
SELECT절 참조 컬럼만 다른데 UNION으로 동일 데이터 **반복 SCAN**

### 튜닝 내용
CASE WHEN으로 한 번만 SCAN하도록 통합

```sql
-- 튜닝 전: UNION으로 반복 SCAN
SELECT 컬럼A, ... FROM 테이블 WHERE 조건1
UNION
SELECT 컬럼B, ... FROM 테이블 WHERE 조건2

-- 튜닝 후: CASE WHEN으로 통합
SELECT 
    CASE WHEN 조건1 THEN 컬럼A 
         WHEN 조건2 THEN 컬럼B 
    END,
    ...
FROM 테이블 
WHERE 조건1 OR 조건2;
```

---

## Section 12. INDEX FULL SCAN(MIN/MAX) 유도

**관련 단원**: INDEX ACCESS 패턴, 페이징 처리

### 바인드 변수
```sql
:B1 -> '20120523'
```

### 원본 SQL
```sql
SELECT 
    CASE WHEN 제로인휴일구분 = '0' 
         THEN 제로인기준일자 
         ELSE 제로인익영업일 
    END AS 주첫번째일자
FROM 일자관리
WHERE 제로인기준일자 = (
    SELECT MAX(제로인기준일자)
    FROM 일자관리
    WHERE 제로인기준일자 <= :B1
      AND 제로인요일구분 = '2'
);
```

### 문제점
[제로인기준일자] 컬럼이 PK INDEX이지만 [제로인기준일자 <= :B1 AND 제로인요일구분 = '2'] 조건으로 인해서 **INDEX FULL SCAN (MIN/MAX) 실행계획이 나타나지 못함**. 이로 인해서 조건에 해당하는 모든 범위를 SCAN 후에 MAX값을 찾는 비효율이 발생하고 있다.

### 튜닝 내용
[제로인기준일자] 컬럼이 PK INDEX이기 때문에 표준 **PAGINATION의 TOP N 쿼리** 방식을 이용해서 SQL을 변경한다. PK INDEX를 역순으로 SCAN 후 ROWNUM <= 1을 사용하면 기준일자가 가장 큰 경우만 SCAN하고 멈추도록 할 수 있다.

### 튜닝 후 SQL
```sql
SELECT 
    CASE WHEN 제로인휴일구분 = '0' 
         THEN 제로인기준일자 
         ELSE 제로인익영업일 
    END AS 주첫번째일자
FROM (
    SELECT 제로인기준일자, 제로인휴일구분, 제로인익영업일
    FROM 일자관리
    WHERE 제로인기준일자 <= :B1
      AND 제로인요일구분 = '2'
    ORDER BY 제로인기준일자 DESC
)
WHERE ROWNUM <= 1;
```

### 성과
- 하루에 200,000번 이상 매우 빈번하게 수행되는 SQL
- **INDEX FULL SCAN(MIN/MAX)** 효과 달성
- I/O 대폭 감소

---

## Section 13. 페이징 후 JOIN + 스칼라 서브쿼리

**관련 단원**: 페이징 처리, 서브쿼리

### 문제점
전체 결과 건수와 외부 테이블 **모두 JOIN 후** 페이징으로 20건 추출 → 불필요한 대량 JOIN

### 튜닝 내용
1. 메인 테이블만으로 **먼저 페이징** (20건 추출)
2. 줄어든 건수에 대해서만 외부 테이블 JOIN  
3. UNIQUE KEY OUTER JOIN + 값 종류 적음 → **스칼라 서브쿼리** (캐싱)

### 튜닝 후 구조
```sql
SELECT 
    메인컬럼들...,
    (SELECT 참조컬럼 FROM 외부테이블 WHERE 조인조건) AS 참조명
FROM (
    SELECT 메인컬럼들...
    FROM 메인테이블
    WHERE 주요조건들
    ORDER BY 정렬조건
)
WHERE ROWNUM <= 20;
```

### 성과
| 지표 | 튜닝 전 | 튜닝 후 | 개선율 |
|------|---------|---------|--------|
| PGA | 802K | **0** | **100%** |
| JOIN 대상 건수 | 15,201건 | **20건** | **99.9%** |

---

## Section 14. JOIN 순서/방법 최적화

**관련 단원**: JOIN

### 문제점
JOIN 순서 비효율 → 많은 건수가 NL JOIN 후 마지막에 대부분 필터링

### 튜닝 내용
- LEADING 힌트로 최적 JOIN 순서 지정
- 대량 JOIN은 HASH JOIN 적용

### 튜닝 후 SQL
```sql
SELECT /*+ LEADING(E D B A C) USE_NL(D B A) USE_HASH(C) */
    E.MOD_NAME, A.ST_NAME, C.ALI, A.TAR,
    C.GRA, C.EP_YN, D.MOD_NAME, D.MOD_PROP
FROM TB_EQ_RT_RS A, TB_EQQ_RT_RS B, TB_PAR_ST_RS C,
     TB_EQ_MT_RS D, TB_EQ_MT_PP E
WHERE A.EQ_RP_RWID = B.RWID
  AND A.PRM_RWID = C.RWID  
  AND B.EQP_RAWID = D.RWID
  AND D.EQP_RAWID = E.RWID
  AND E.MOD_NAME = :1
  AND B.RP_ID = :2
  AND B.RP_ID NOT LIKE :SYS_B_0
ORDER BY A.ST_NAME, C.ALI;
```

### 성과
JOIN 순서 변경: E-D-B-C-A → E-D-B-A-C로 최적화

---

## Section 15. JPPD로 인라인뷰 GROUP BY 제거

**관련 단원**: JOIN (JPPD)

### 문제점
선행 결과 276건인데 인라인뷰에서 **전체 데이터 GROUP BY** 발생 → 대부분 버림 + PGA 대량 사용

### 튜닝 내용
JPPD로 선행 건수만 인라인뷰에 침투 → 전체 GROUP BY 제거

### 튜닝 후 SQL
```sql
SELECT /*+ 
    OPT_PARAM('_optimizer_cost_based_transformation' 'on')
    OPT_PARAM('_optimizer_push_pred_cost_based' 'true')
    NO_MERGE(MST) USE_NL(MST)
    INDEX(MS TB_RETURN_SLP_IDX6)
*/
    MS.SLP_NO,
    ...
FROM TB_RETURN_SLP MS,
     (SELECT SLP_NO, MA_CODE, SUM(MA_QTY) MA_QTY,
             FG_CODE, STP, MA_TYPE, PR_CODE
      FROM TB_RETURN_SHT
      GROUP BY SLP_NO, MA_CODE, FG_CODE, STP, MA_TYPE, PR_CODE) MST
WHERE :SYS_B_12 = :SYS_B_13
  AND MS.SLP_NO = MST.SLP_NO(+)
  AND MS.SLP_STAT LIKE :SYS_B_21
  AND MS.SLP_TYPE LIKE :SYS_B_22  
  AND MST.MA_CODE LIKE :SYS_B_23
  AND MST.MA_TYPE LIKE :SYS_B_24
ORDER BY MS.SLP_NO DESC, MST.MA_CODE, MST.MA_QTY;
```

### 성과
- 실행 계획에 **VIEW PUSHED PREDICATE** 확인
- 전체 GROUP BY 제거로 PGA 사용량 대폭 감소

---

## Section 16. JOIN 순서/방법 + 서브쿼리 최적화

**관련 단원**: 서브쿼리

### 문제점
메인 쿼리와 서브쿼리의 JOIN 순서/방법이 비효율적 → 대량 I/O 발생

### 원본 SQL 구조
```sql
SELECT MA_ID, EQP_ID, ORI_STP_ID, SUBSTR(MA_LC_ID, 0, 8) MA_LC_ID
FROM TB_MA_HST A
WHERE 1 = 1
  AND OCR_TIME >= TO_CHAR(SYSDATE - 3/24, 'YYYYMMDD HH24') || '0000'
  AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
  AND (EQP_ID, ORI_STP_ID, LT_ID) IN (
      SELECT /*+ UNNEST HASH_SJ SWAP_JOIN_INPUTS(A) */
             EQP_ID, ORI_STP_ID, LT_ID
      FROM TB_LT_HST A
      WHERE 1 = 1
        AND OCR_TIME >= TO_CHAR(SYSDATE - 1/24, 'YYYYMMDD HH24') || '0000'  
        AND OCR_TIME < TO_CHAR(SYSDATE, 'YYYYMMDD HH24') || '0000'
        AND OCR_NAME = 'TrackOut'
        AND SUBSTR(EQP_ID, 3, 3) IN (
            SELECT ITEM_ID FROM TB_DES_INF WHERE GROUP_ID = 'DB_DES_MONIT'
        )
  )
  AND OCR_NAME = 'compOut'
  AND LOT_TYPE = 'S';
```

### 튜닝 내용
- JOIN 순서 변경
- 서브쿼리 최적화
- HASH SEMI JOIN 활용

### 성과
I/O 대폭 감소로 성능 향상

---

## 핵심 튜닝 패턴 총정리 ✅

### 1. INDEX 관련
| 패턴 | 상황 | 해법 |
|------|------|------|
| **INDEX SKIP SCAN** | 중간 컬럼 누락 + DISTINCT 값 적음 | `INDEX_SS` 힌트 |
| **적절한 INDEX 선택** | 옵티마이저가 잘못된 INDEX 선택 | `INDEX` 힌트로 지정 |
| **INDEX FULL SCAN(MIN/MAX)** | 복합 조건으로 MIN/MAX 미발생 | TOP N 쿼리 구조 변경 |

### 2. JOIN 관련  
| 패턴 | 상황 | 해법 |
|------|------|------|
| **NL → HASH JOIN** | 많은 건수 NL JOIN + 테이블 사이즈 작음 | `USE_HASH` 힌트 |
| **JPPD** | 인라인뷰/UNION ALL VIEW 침투 안 됨 | `USE_NL` + `NO_MERGE` |
| **JOIN 순서 변경** | 비효율적 순서로 대량 필터링 | `LEADING` 힌트 |
| **JOIN → 스칼라 서브쿼리** | DISTINCT 값 적은 UNIQUE KEY JOIN | 스칼라 서브쿼리 캐싱 |

### 3. 서브쿼리/반복 ACCESS
| 패턴 | 상황 | 해법 |
|------|------|------|
| **MAX() 서브쿼리 → EXISTS** | 동일 테이블 반복 SCAN | EXISTS로 변환 |
| **UNION → CASE WHEN** | 동일 데이터 반복 ACCESS | CASE WHEN 통합 |
| **실행 계획 분리** | OPTIONAL 바인드로 INDEX 사용 불가 | UNION ALL 분리 |
| **COALESCE 활용** | UNION으로 중복 제거 | COALESCE 스칼라 서브쿼리 |

### 4. 페이징
| 패턴 | 상황 | 해법 |
|------|------|------|
| **페이징 후 JOIN** | 전체 JOIN 후 페이징 | 먼저 페이징 → 줄어든 건수로 JOIN |
| **TOP N 쿼리** | MIN/MAX 비효율 | ORDER BY + ROWNUM 활용 |

### 5. PGA 튜닝
| 패턴 | 상황 | 해법 |
|------|------|------|
| **WINDOW 함수** | 반복 GROUP BY/SORT | RANK(), ROW_NUMBER() 등 |
| **WITH절 + MATERIALIZE** | 동일 데이터 반복 ACCESS | 임시 테이블 생성 |

### 6. 고급 힌트 활용
| 힌트 | 용도 | 예시 |
|------|------|------|
| **OPT_PARAM** | 옵티마이저 파라미터 조정 | `_optimizer_push_pred_cost_based` |
| **MATERIALIZE** | WITH절 임시 테이블 생성 | 중복 ACCESS 제거 |
| **UNNEST** | 서브쿼리 unnesting 강제 | IN절 서브쿼리 최적화 |
| **HASH_SJ** | HASH SEMI JOIN 유도 | EXISTS/IN 최적화 |

---

## 실무 적용 가이드라인 🎯

### 문제 진단 순서
1. **실행계획 분석**: Starts, A-Rows, Buffers, A-Time 확인
2. **병목 지점 파악**: 가장 많은 리소스를 사용하는 Operation 식별  
3. **데이터 특성 파악**: 테이블 사이즈, DISTINCT 값 종류, JOIN 관계
4. **액세스 패턴 분석**: INDEX 사용 여부, FULL SCAN 원인

### 튜닝 우선순위
1. **INDEX 최적화**: 적절한 ACCESS PATH 보장
2. **JOIN 최적화**: 순서/방법 조정으로 I/O 최소화
3. **반복 제거**: 동일 데이터 중복 ACCESS 제거
4. **PGA 관리**: SORT/HASH 메모리 사용량 최적화

### 성능 측정 지표
- **Buffer Gets**: 논리적 I/O 횟수 (가장 중요)
- **Physical Reads**: 물리적 I/O 횟수
- **A-Time**: 실제 수행 시간
- **PGA 사용량**: 메모리 사용량

> 💡 **핵심**: 복잡해 보이는 SQL도 기본 패턴의 조합이다. 단계별로 접근하면 반드시 해결할 수 있다!