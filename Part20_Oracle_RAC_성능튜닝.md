# Part 20. Oracle RAC 성능 튜닝

> 📖 **출처:** Oracle Database 19c RAC Administration and Deployment Guide, Oracle Performance Tuning Guide  
> 📝 **정리:** 루나 (2026-03-23)

---

## 📚 목차

| Section | 제목 | 바로가기 |
|---------|------|----------|
| 01 | RAC 아키텍처와 성능 특성 | [바로가기](#-section-01-rac-아키텍처와-성능-특성) |
| 02 | Interconnect 성능 튜닝 | [바로가기](#-section-02-interconnect-성능-튜닝) |
| 03 | Cache Fusion 최적화 | [바로가기](#-section-03-cache-fusion-최적화) |
| 04 | RAC Wait Event 분석 | [바로가기](#-section-04-rac-wait-event-분석) |
| 05 | 워크로드 분산 전략 | [바로가기](#-section-05-워크로드-분산-전략) |
| 06 | Sequence 및 Index Contention | [바로가기](#-section-06-sequence-및-index-contention) |
| 07 | Undo 및 Temp 튜닝 | [바로가기](#-section-07-undo-및-temp-튜닝) |
| 08 | RAC 환경 SQL 튜닝 | [바로가기](#-section-08-rac-환경-sql-튜닝) |
| 09 | AWR/ASH/ADDM RAC 분석 | [바로가기](#-section-09-awrashaddm-rac-분석) |
| 10 | 실전 트러블슈팅 사례 | [바로가기](#-section-10-실전-트러블슈팅-사례) |

---

## 🔷 Section 01. RAC 아키텍처와 성능 특성

### 1.1 RAC 구조 개요 (Shared Everything)

Oracle RAC(Real Application Clusters)는 **Shared Everything** 아키텍처로, 여러 인스턴스가 하나의 공유 스토리지에 동시에 접근한다.

```
┌─────────────────────────────────────────────────────────┐
│                    Shared Storage (ASM)                  │
│         Datafiles / Redo Logs / Control Files            │
└────────────────┬──────────────────┬─────────────────────┘
                 │                  │
    ┌────────────┴───┐    ┌────────┴────────┐
    │  Instance 1    │    │  Instance 2     │
    │  ┌──────────┐  │    │  ┌──────────┐   │
    │  │ SGA      │  │    │  │ SGA      │   │
    │  │┌────────┐│  │    │  │┌────────┐│   │
    │  ││Buffer  ││◄─┼────┼──┤│Buffer  ││   │
    │  ││Cache   ││  │    │  ││Cache   ││   │
    │  │└────────┘│  │    │  │└────────┘│   │
    │  │┌────────┐│  │    │  │┌────────┐│   │
    │  ││Shared  ││  │    │  ││Shared  ││   │
    │  ││Pool    ││  │    │  ││Pool    ││   │
    │  │└────────┘│  │    │  │└────────┘│   │
    │  └──────────┘  │    │  └──────────┘   │
    │                │    │                  │
    │  GCS/GES       │    │  GCS/GES        │
    │  (LMS/LMD/LMON)│    │  (LMS/LMD/LMON) │
    └───────┬────────┘    └────────┬─────────┘
            │    Private Interconnect    │
            └────────────┬───────────────┘
                   (Cache Fusion)
```

### 1.2 핵심 RAC 컴포넌트

| 컴포넌트 | 약칭 | 역할 |
|----------|------|------|
| Global Cache Service | GCS | 데이터 블록의 인스턴스 간 전송 관리 (LMS 프로세스) |
| Global Enqueue Service | GES | 글로벌 락/인큐 관리 (LMD 프로세스) |
| Cache Fusion | - | 인스턴스 간 블록을 Interconnect를 통해 직접 전송 |
| LMON | - | Global Enqueue Service Monitor, 노드 멤버십 관리 |
| LMS | - | Global Cache Service Process, 블록 전송 담당 |
| LMD | - | Global Enqueue Service Daemon, 락 요청 처리 |
| LCK0 | - | Non-Cache Fusion 리소스 락 관리 |

### 1.3 Single Instance vs RAC 성능 차이점

| 항목 | Single Instance | RAC |
|------|----------------|-----|
| 블록 읽기 | 디스크 or 로컬 캐시 | 디스크 or 로컬 캐시 or **원격 캐시 (Cache Fusion)** |
| Lock 관리 | 로컬 Enqueue | **Global Enqueue** (Cross-Instance) |
| Redo 관리 | 1개 Redo Thread | **인스턴스별 Redo Thread** |
| Undo 관리 | 1개 Undo Tablespace | **인스턴스별 Undo Tablespace** |
| 오버헤드 | 없음 | **Interconnect 통신 + GCS/GES 오버헤드** |
| 확장성 | Scale-Up만 | **Scale-Out 가능** |

### 1.4 RAC 고유 Wait Event (gc 계열)

RAC에서 추가로 발생하는 대기 이벤트는 대부분 `gc` (Global Cache) 접두어를 가진다.

| Wait Event | 설명 | 일반적인 원인 |
|------------|------|--------------|
| `gc cr request` | CR 블록을 원격 인스턴스에서 요청 | 인스턴스 간 데이터 공유 |
| `gc current request` | Current 블록을 원격 인스턴스에서 요청 | 동일 블록에 대한 DML 경합 |
| `gc buffer busy acquire` | GCS 요청 후 버퍼 획득 대기 | 핫 블록 경합 |
| `gc buffer busy release` | 블록 전송 완료 대기 | LMS 프로세스 과부하 |
| `gc cr multi block request` | 멀티블록 CR 읽기 | Full Table Scan |
| `gc current grant busy` | Current 모드 그랜트 대기 | Interconnect 지연 |

```sql
-- RAC 관련 Wait Event 현황 조회
SELECT inst_id, event, total_waits, time_waited_micro/1e6 AS time_waited_sec,
       ROUND(average_wait_micro/1e3, 2) AS avg_wait_ms
FROM   gv$system_event
WHERE  event LIKE 'gc%'
ORDER BY time_waited_micro DESC
FETCH FIRST 20 ROWS ONLY;
```

<details>
<summary>📌 RAC Wait Event 분류 체계 상세</summary>

```
gc Wait Event 체계
├── gc cr request          ← CR 블록 요청 (SELECT)
├── gc cr grant 2-way      ← 마스터에게서 직접 grant
├── gc cr grant busy       ← 마스터가 바쁨
├── gc current request     ← Current 블록 요청 (DML)
├── gc current grant 2-way ← 마스터에게서 직접 grant
├── gc current grant busy  ← 마스터가 바쁨
├── gc buffer busy acquire ← 로컬에서 버퍼 대기
├── gc buffer busy release ← 원격에서 릴리즈 대기
├── gc cr block busy       ← CR 블록 전송 중 바쁨
├── gc current block busy  ← Current 블록 전송 중 바쁨
├── gc cr block 2-way      ← 홀더에게서 CR 블록 수신 (정상)
├── gc cr block 3-way      ← 마스터→홀더→요청자 (정상)
├── gc current block 2-way ← 홀더에게서 Current 블록 수신
└── gc current block 3-way ← 마스터→홀더→요청자
```

- **2-way**: 요청 노드 → 마스터 노드 → 요청 노드 (마스터가 블록 보유)
- **3-way**: 요청 노드 → 마스터 노드 → 홀더 노드 → 요청 노드

</details>

> 💡 **실무 팁**  
> RAC 환경에서 `gc cr/current block 2-way`와 `3-way` 이벤트 자체는 **정상적인 Cache Fusion 동작**이다. 평균 대기 시간이 **1ms 미만**이면 건강한 상태. **3ms 이상**이면 Interconnect 점검이 필요하다.

> ⚠️ **주의**  
> `gc buffer busy acquire/release`가 Top Wait Event에 올라오면 **핫 블록 경합**이 심각한 것이다. SQL 튜닝으로 접근 블록 수를 줄이거나 워크로드 분리가 필요하다.

---

## 🔷 Section 02. Interconnect 성능 튜닝

### 2.1 Private Interconnect 네트워크 최적화

Interconnect는 RAC 성능의 **생명선**이다. Cache Fusion의 모든 블록 전송이 이 네트워크를 통해 이루어진다.

```
┌──────────────┐     Private Interconnect      ┌──────────────┐
│  Instance 1  │◄──────────────────────────────►│  Instance 2  │
│              │    (10GbE / 25GbE / InfiniBand)│              │
│  eth0: Public│                                │  eth0: Public│
│  eth1: Priv  │     Low Latency (<100μs)       │  eth1: Priv  │
│  eth2: Priv  │     High Bandwidth (>1Gbps)    │  eth2: Priv  │
│  (bonding)   │                                │  (bonding)   │
└──────────────┘                                └──────────────┘
```

| 항목 | 권장 사항 |
|------|----------|
| 대역폭 | **최소 10GbE**, 권장 25GbE 이상 |
| 지연 시간 | **100μs 이하** |
| NIC Bonding | Active-Active (LACP/802.3ad) 권장 |
| VLAN | Interconnect 전용 VLAN 분리 |
| 방화벽 | Interconnect 경로에 **절대 방화벽 금지** |

### 2.2 UDP vs RDS 프로토콜

| 프로토콜 | 특성 | 사용 환경 |
|----------|------|----------|
| UDP (기본) | 범용, OS 네트워크 스택 사용 | Ethernet 환경 |
| RDS (Reliable Datagram Sockets) | 커널 바이패스, 낮은 CPU 오버헤드 | InfiniBand 환경 |

```sql
-- 현재 Interconnect 프로토콜 확인
SELECT inst_id, name, ip_address, is_public, source
FROM   gv$cluster_interconnects;

-- Interconnect 전송량 확인
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name IN ('gc cr blocks received', 'gc current blocks received',
                'gc cr blocks served', 'gc current blocks served')
ORDER BY inst_id, name;
```

### 2.3 Jumbo Frame 설정

Jumbo Frame(MTU 9000)은 Interconnect 성능을 **15~20%** 향상시킬 수 있다.

```bash
# Linux에서 Jumbo Frame 설정 확인
ip link show eth1  # MTU 확인

# Jumbo Frame 설정 (영구 적용은 ifcfg 파일 수정)
ip link set eth1 mtu 9000

# /etc/sysconfig/network-scripts/ifcfg-eth1 (RHEL 기준)
# MTU=9000

# 모든 노드 + 스위치에서 동일하게 설정해야 함
# 테스트
ping -M do -s 8972 <상대노드_IP>   # 8972 + 28(헤더) = 9000
```

> ⚠️ **주의**  
> Jumbo Frame은 **Interconnect 경로의 모든 장비**(NIC, 스위치, 상대 노드)에서 동일하게 설정해야 한다. 하나라도 빠지면 패킷 단편화(fragmentation)가 발생하여 오히려 성능이 저하된다.

### 2.4 대역폭 모니터링

```sql
-- oifcfg로 Interconnect 설정 확인 (OS 명령)
-- $ oifcfg getif
-- $ oifcfg iflist

-- AWR에서 Interconnect 트래픽 확인
SELECT snap_id, instance_number,
       ROUND(bytes_sent/1024/1024, 2) AS sent_mb,
       ROUND(bytes_received/1024/1024, 2) AS recv_mb
FROM   dba_hist_interconnect_pings
WHERE  snap_id BETWEEN &begin_snap AND &end_snap
ORDER BY snap_id, instance_number;

-- 실시간 Interconnect 트래픽 (초당)
SELECT inst_id, 
       ROUND(value / (SYSDATE - startup_time) / 86400, 2) AS blocks_per_sec
FROM   gv$sysstat s, gv$instance i
WHERE  s.inst_id = i.inst_id
AND    s.name = 'gc cr blocks received';
```

<details>
<summary>📌 Interconnect 병목 진단 스크립트</summary>

```sql
-- Interconnect 평균 전송 시간 분석
SELECT b.inst_id,
       ROUND(a.average_wait, 2) AS avg_wait_ms,
       a.event,
       a.total_waits,
       ROUND(a.time_waited_micro/1e6, 2) AS total_wait_sec
FROM   gv$system_event a, gv$instance b
WHERE  a.inst_id = b.inst_id
AND    a.event IN ('gc cr block 2-way',
                   'gc cr block 3-way',
                   'gc current block 2-way',
                   'gc current block 3-way')
ORDER BY a.time_waited_micro DESC;

-- 결과 해석:
-- avg_wait < 1ms  : 우수 (정상)
-- avg_wait 1~3ms  : 양호
-- avg_wait 3~10ms : 주의 (Interconnect 점검)
-- avg_wait > 10ms : 심각 (네트워크 병목)
```

```bash
# OS 레벨 Interconnect 모니터링
# 실시간 네트워크 사용량 (sar)
sar -n DEV 1 5 | grep eth1

# 패킷 에러/드롭 확인
netstat -i | grep eth1
# 또는
ip -s link show eth1

# TCP retransmit 확인 (Interconnect 문제 지표)
netstat -s | grep -i retrans
```

</details>

> 💡 **실무 팁**  
> AWR Report의 **"Interconnect Ping Latency Stats"** 섹션에서 노드 간 지연 시간을 확인할 수 있다. `500 bytes` 핑이 **0.5ms 이상**이면 네트워크 점검이 필요하다. `8K bytes` 핑은 실제 블록 전송 성능을 반영한다.

---

## 🔷 Section 03. Cache Fusion 최적화

### 3.1 Global Cache 동작 원리

Cache Fusion은 디스크 I/O 없이 **인스턴스 간 Interconnect를 통해 블록을 직접 전송**하는 메커니즘이다.

#### 2-way Transfer (마스터가 블록 보유)

```
Instance 1 (요청자)          Instance 2 (마스터 & 홀더)
     │                              │
     │──── ① Block Request ────────►│
     │                              │
     │◄─── ② Block Transfer ────────│
     │                              │
  [블록 수신]                    [블록 전송]
```

#### 3-way Transfer (마스터 ≠ 홀더)

```
Instance 1 (요청자)    Instance 2 (마스터)    Instance 3 (홀더)
     │                       │                       │
     │── ① Request ─────────►│                       │
     │                       │── ② Forward ─────────►│
     │                       │                       │
     │◄────────────── ③ Block Transfer ──────────────│
     │                       │                       │
  [블록 수신]           [라우팅만]              [블록 전송]
```

### 3.2 gc buffer busy 분석

| Wait Event | 발생 상황 | 해결 방안 |
|------------|----------|----------|
| `gc buffer busy acquire` | 로컬 인스턴스에서 같은 블록을 여러 세션이 동시 요청 | 핫 블록 분산, ASSM 사용 |
| `gc buffer busy release` | 원격 블록 전송 완료를 기다림 | LMS 프로세스 수 증가, Interconnect 점검 |
| `gc cr block busy` | CR 블록 생성/전송 지연 | Undo 튜닝, LMS 부하 분산 |
| `gc current block busy` | Current 블록 전송 지연 | DML 경합 해소, 워크로드 분리 |

```sql
-- 핫 블록 식별: gc buffer busy가 많은 블록 찾기
SELECT *
FROM (
  SELECT ash.current_obj#, 
         ash.current_file#, 
         ash.current_block#,
         o.object_name,
         o.object_type,
         COUNT(*) AS wait_count
  FROM   gv$active_session_history ash
  LEFT JOIN dba_objects o ON ash.current_obj# = o.object_id
  WHERE  ash.event LIKE 'gc buffer busy%'
  AND    ash.sample_time > SYSDATE - INTERVAL '1' HOUR
  GROUP BY ash.current_obj#, ash.current_file#, ash.current_block#,
           o.object_name, o.object_type
  ORDER BY COUNT(*) DESC
)
WHERE ROWNUM <= 10;
```

### 3.3 DRM (Dynamic Resource Mastering)

DRM은 **자주 접근하는 리소스의 마스터링을 해당 인스턴스로 이동**시켜 3-way를 2-way로 줄이는 메커니즘이다.

```
DRM 동작 전:
  Inst1 ──요청──► Inst2(마스터) ──전달──► Inst3(홀더) ──블록──► Inst1
  (3-way: 네트워크 홉 3번)

DRM Remastering 후:
  Inst1(마스터&홀더) ── 로컬 접근
  (0-way: 네트워크 홉 0번)
```

| DRM 파라미터 | 기본값 | 설명 |
|-------------|--------|------|
| `_gc_policy_time` | 10 (분) | DRM 재마스터링 평가 주기 |
| `_gc_affinity_time` | 10 (분) | Affinity 기반 리마스터링 주기 |
| `_gc_undo_affinity` | TRUE | Undo 세그먼트 Affinity 활성화 |

```sql
-- DRM Remastering 현황 확인
SELECT inst_id, object_name, current_master, previous_master, remaster_cnt
FROM   gv$gcshvmaster_info
WHERE  remaster_cnt > 0
ORDER BY remaster_cnt DESC
FETCH FIRST 20 ROWS ONLY;

-- DRM 비활성화 (경합 심할 때 임시 조치)
-- ALTER SYSTEM SET "_gc_policy_time" = 0 SCOPE=BOTH SID='*';
```

> ⚠️ **주의**  
> `_gc_policy_time = 0`으로 DRM을 비활성화하면 리마스터링 오버헤드는 없어지지만, 3-way 전송이 증가할 수 있다. **운영 중 DRM 비활성화는 충분한 테스트 후에만** 적용해야 한다.

<details>
<summary>📌 DRM 관련 히든 파라미터 상세</summary>

```sql
-- DRM 관련 히든 파라미터 조회
SELECT ksppinm AS parameter, ksppdesc AS description, ksppstvl AS value
FROM   x$ksppi a, x$ksppcv b
WHERE  a.indx = b.indx
AND    a.ksppinm LIKE '%_gc_%'
ORDER BY a.ksppinm;

-- 주요 DRM 히든 파라미터
-- _gc_policy_time       = 10     리마스터링 평가 주기(분)
-- _gc_affinity_time     = 10     Affinity 평가 주기(분)  
-- _gc_affinity_limit    = 50     Affinity 판정 임계치(%)
-- _gc_undo_affinity     = TRUE   Undo affinity 활성화
-- _gc_bypass_readers    = 10     Reader bypass 임계치
-- _gc_read_mostly_locking = TRUE Read-Mostly 최적화
-- _gc_policy_minimum    = 1500   최소 터치 카운트

-- Remastering 이력 확인 (Alert Log에서도 확인 가능)
SELECT *
FROM   gv$dynamic_remaster_stats
ORDER BY remaster_ops DESC;
```

</details>

> 💡 **실무 팁**  
> RAC에서 **특정 테이블을 주로 접근하는 인스턴스가 명확**하다면, 해당 테이블을 특정 인스턴스에 고정 마스터링(`_gc_affinity_limit` 조절)하는 것이 성능에 유리하다. 하지만 19c 이상에서는 DRM이 자동으로 잘 동작하므로 수동 개입은 최소화하자.

---

## 🔷 Section 04. RAC Wait Event 분석

### 4.1 gc 계열 Wait Event 상세

#### gc cr request / gc current request

```sql
-- gc 계열 Wait Event Top-N 분석
SELECT event, 
       total_waits,
       ROUND(time_waited_micro/1e6, 2) AS total_sec,
       ROUND(average_wait_micro/1e3, 2) AS avg_ms,
       wait_class
FROM   gv$system_event
WHERE  wait_class = 'Cluster'
ORDER BY time_waited_micro DESC
FETCH FIRST 15 ROWS ONLY;
```

| Wait Event | 의미 | 정상 범위 | 조치 |
|------------|------|----------|------|
| gc cr request | CR 블록 원격 요청 | < 1ms | Interconnect 점검 |
| gc current request | Current 블록 원격 요청 | < 1ms | DML 경합 해소 |
| gc cr grant 2-way | 마스터가 CR 권한 부여 | < 0.5ms | 정상 |
| gc current grant 2-way | 마스터가 Current 권한 부여 | < 0.5ms | 정상 |
| gc cr block 2-way | 마스터에서 CR 블록 수신 | < 1ms | 정상 |
| gc cr block 3-way | 홀더에서 CR 블록 수신 | < 1.5ms | 정상 |
| gc current block 2-way | 마스터에서 Current 블록 수신 | < 1ms | 정상 |
| gc current block 3-way | 홀더에서 Current 블록 수신 | < 1.5ms | 정상 |

### 4.2 Library Cache Lock/Pin in RAC

RAC 환경에서 Library Cache 관련 경합은 **글로벌**로 확대된다.

```sql
-- Library Cache Lock 경합 확인
SELECT inst_id, event, p1text, p1, p2text, p2, p3text, p3, 
       blocking_instance, blocking_session
FROM   gv$session
WHERE  event LIKE 'library cache%'
AND    state = 'WAITING';

-- DDL 수행 시 RAC 전체 인스턴스에 영향
-- Instance 1에서 ALTER TABLE → Instance 2의 해당 테이블 커서 무효화
```

| Library Cache 이벤트 | RAC에서의 특성 |
|---------------------|--------------|
| library cache lock | DDL 시 **모든 인스턴스**의 관련 커서에 락 필요 |
| library cache pin | 파싱/컴파일 시 **글로벌 핀** 필요 |
| cursor: pin S wait on X | Hard Parse 경합, RAC에서 증폭 |

> 💡 **실무 팁**  
> RAC 환경에서 **DDL(ALTER, GRANT 등)은 피크 시간을 피해** 수행해야 한다. DDL은 모든 인스턴스의 관련 커서를 무효화하여 대량 Hard Parse를 유발한다.

### 4.3 enq: TX - row lock contention (Cross-Instance)

```sql
-- Cross-Instance Row Lock 확인
SELECT s.inst_id AS waiter_inst,
       s.sid AS waiter_sid,
       s.blocking_instance AS blocker_inst,
       s.blocking_session AS blocker_sid,
       s.event,
       s.seconds_in_wait,
       s.sql_id
FROM   gv$session s
WHERE  s.event = 'enq: TX - row lock contention'
AND    s.blocking_instance IS NOT NULL
AND    s.blocking_instance != s.inst_id;  -- Cross-Instance만

-- 블로커 세션 상세 정보
SELECT inst_id, sid, serial#, username, program, sql_id, 
       status, last_call_et
FROM   gv$session
WHERE  inst_id = &blocker_inst
AND    sid = &blocker_sid;
```

### 4.4 AWR/ASH에서 RAC 관련 분석

```sql
-- AWR에서 인스턴스별 Top Wait Event 비교
SELECT snap_id, instance_number, event_name,
       total_waits, total_timeouts,
       ROUND(time_waited_micro/1e6, 2) AS wait_sec,
       ROUND(time_waited_micro/NULLIF(total_waits,0)/1e3, 2) AS avg_ms
FROM   dba_hist_system_event
WHERE  snap_id BETWEEN &begin_snap AND &end_snap
AND    wait_class = 'Cluster'
ORDER BY instance_number, time_waited_micro DESC;

-- ASH에서 gc 이벤트 시계열 분석
SELECT TO_CHAR(sample_time, 'HH24:MI') AS time_slot,
       instance_number,
       event,
       COUNT(*) AS sample_count
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN &begin_time AND &end_time
AND    event LIKE 'gc%'
GROUP BY TO_CHAR(sample_time, 'HH24:MI'), instance_number, event
ORDER BY time_slot, instance_number;
```

<details>
<summary>📌 RAC Wait Event 진단 종합 스크립트</summary>

```sql
-- 1. Cluster Wait Class 비율 확인
SELECT ROUND(cluster_wait / total_wait * 100, 2) AS cluster_pct
FROM (
  SELECT SUM(CASE WHEN wait_class = 'Cluster' THEN time_waited_micro END) AS cluster_wait,
         SUM(time_waited_micro) AS total_wait
  FROM   gv$system_event
  WHERE  wait_class != 'Idle'
);
-- cluster_pct > 30% 이면 RAC 경합이 심각

-- 2. 인스턴스별 gc 블록 전송 효율
SELECT inst_id,
       SUM(CASE WHEN name LIKE 'gc cr blocks%received' THEN value END) AS cr_received,
       SUM(CASE WHEN name LIKE 'gc current blocks%received' THEN value END) AS cur_received,
       SUM(CASE WHEN name LIKE 'gc cr blocks%served' THEN value END) AS cr_served,
       SUM(CASE WHEN name LIKE 'gc current blocks%served' THEN value END) AS cur_served
FROM   gv$sysstat
WHERE  name LIKE 'gc%blocks%'
GROUP BY inst_id;

-- 3. Lost Block 확인 (재전송 필요한 블록)
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name LIKE 'gc%lost%'
AND    value > 0;
-- lost > 0 이면 Interconnect 문제
```

</details>

> ⚠️ **주의**  
> `gc blocks lost` 통계가 **0이 아니면** Interconnect에 심각한 문제가 있다는 신호다. 패킷 유실이 발생하고 있으므로 즉시 네트워크 점검이 필요하다.

---

## 🔷 Section 05. 워크로드 분산 전략

### 5.1 Service 기반 워크로드 분리

RAC 성능 최적화의 **가장 효과적인 방법**은 워크로드를 인스턴스별로 분리하는 것이다.

```
┌─────────────────────────────────────────────────────┐
│                  Application Tier                    │
│                                                      │
│  OLTP App ──► SVC_OLTP ──► Instance 1 (Preferred)   │
│                              Instance 2 (Available)  │
│                                                      │
│  Batch App ──► SVC_BATCH ──► Instance 2 (Preferred) │
│                               Instance 1 (Available) │
│                                                      │
│  Report App ──► SVC_RPT ──► Instance 2 (Preferred)  │
│                              Instance 1 (Available)  │
└─────────────────────────────────────────────────────┘
```

```sql
-- Service 생성 (srvctl 사용)
-- $ srvctl add service -db PRODDB -service SVC_OLTP \
--   -preferred PROD1 -available PROD2 \
--   -clbgoal SHORT -rlbgoal SERVICE_TIME

-- $ srvctl add service -db PRODDB -service SVC_BATCH \
--   -preferred PROD2 -available PROD1 \
--   -clbgoal LONG -rlbgoal THROUGHPUT

-- Service 시작
-- $ srvctl start service -db PRODDB -service SVC_OLTP
-- $ srvctl start service -db PRODDB -service SVC_BATCH

-- Service 상태 확인
SELECT inst_id, name, network_name, goal, clb_goal
FROM   gv$active_services
WHERE  name NOT LIKE 'SYS%'
ORDER BY inst_id, name;
```

### 5.2 Application Partitioning

| 분리 전략 | 설명 | 효과 |
|----------|------|------|
| OLTP / Batch 분리 | 온라인 트랜잭션은 Inst1, 배치는 Inst2 | gc 경합 70~80% 감소 |
| Read / Write 분리 | 읽기는 Inst2, 쓰기는 Inst1 | Current 블록 경합 감소 |
| 테이블 기반 분리 | 주문=Inst1, 재고=Inst2 | 핫 블록 경합 최소화 |

```sql
-- JDBC 연결 문자열에서 Service 지정
-- jdbc:oracle:thin:@(DESCRIPTION=
--   (ADDRESS_LIST=
--     (ADDRESS=(PROTOCOL=TCP)(HOST=scan-host)(PORT=1521)))
--   (CONNECT_DATA=
--     (SERVICE_NAME=SVC_OLTP)))
```

### 5.3 Connection Load Balancing vs Runtime Load Balancing

| 구분 | CLB (Connection LB) | RLB (Runtime LB) |
|------|---------------------|-------------------|
| 시점 | 연결 생성 시 | 연결 풀에서 연결 선택 시 |
| 파라미터 | CLB_GOAL (SHORT/LONG) | RLB_GOAL (SERVICE_TIME/THROUGHPUT) |
| 동작 | SCAN Listener가 라운드로빈 또는 부하 기반 | FAN 이벤트로 연결 풀이 동적 조절 |
| 적용 대상 | 모든 클라이언트 | UCP/OCI 연결 풀 사용 시 |

```sql
-- CLB_GOAL 설정
-- SHORT: 세션 수 기반 밸런싱 (OLTP)
-- LONG: 응답시간 기반 밸런싱 (Batch)
-- $ srvctl modify service -db PRODDB -service SVC_OLTP -clbgoal SHORT

-- RLB_GOAL 설정
-- SERVICE_TIME: 응답 시간 최적화 (OLTP)
-- THROUGHPUT: 처리량 최적화 (Batch)
-- $ srvctl modify service -db PRODDB -service SVC_OLTP -rlbgoal SERVICE_TIME
```

### 5.4 FAN (Fast Application Notification)

FAN은 RAC 상태 변화(인스턴스 다운, 서비스 시작/중지)를 **애플리케이션에 즉시 통보**하는 메커니즘이다.

```
RAC 이벤트 발생 (Instance Down)
    │
    ├──► ONS (Oracle Notification Service) ──► 연결 풀
    │                                          │
    │                                    ┌─────┴──────┐
    │                                    │ 죽은 연결   │
    │                                    │ 즉시 정리   │
    │                                    │ 살아있는    │
    │                                    │ 인스턴스로  │
    │                                    │ 재라우팅    │
    │                                    └────────────┘
    │
    └──► TAF/FCF: 진행 중인 작업 failover
```

```sql
-- FAN 이벤트 확인
SELECT * FROM gv$ha_ping;

-- ONS 설정 확인 (OS)
-- $ srvctl config nodeapps -s
-- $ cat $ORACLE_HOME/opmn/conf/ons.config
```

> 💡 **실무 팁**  
> Service 기반 워크로드 분리는 RAC 튜닝에서 **투자 대비 효과가 가장 큰** 전략이다. SQL 한 줄 안 바꾸고도 gc 경합을 **60~80% 줄일 수 있다**. 신규 RAC 구축 시 반드시 Service 설계부터 시작하자.

---

## 🔷 Section 06. Sequence 및 Index Contention

### 6.1 Sequence Cache Size 튜닝

RAC에서 Sequence는 **인스턴스 간 가장 흔한 경합 원인** 중 하나다.

| Sequence 옵션 | RAC 영향 | 권장 |
|--------------|---------|------|
| CACHE 20 (기본) | 20개마다 글로벌 동기화 → 심각한 경합 | ❌ |
| CACHE 1000+ | 동기화 빈도 대폭 감소 | ✅ OLTP |
| NOORDER | 인스턴스별 독립 캐시, 번호 순서 보장 안 됨 | ✅ 성능 우선 |
| ORDER | 글로벌 순서 보장, 매번 동기화 | ❌ 성능 저하 |
| NOCACHE | 매번 딕셔너리 접근 | ❌❌ 절대 금지 |

```sql
-- 문제가 되는 Sequence 찾기
SELECT sequence_owner, sequence_name, cache_size, order_flag, last_number
FROM   dba_sequences
WHERE  cache_size < 100
AND    sequence_owner NOT IN ('SYS','SYSTEM')
ORDER BY cache_size;

-- Sequence 캐시 크기 변경
ALTER SEQUENCE hr.emp_seq CACHE 5000 NOORDER;

-- Sequence 관련 Wait Event 확인
SELECT event, total_waits, 
       ROUND(time_waited_micro/1e6, 2) AS time_sec
FROM   gv$system_event
WHERE  event LIKE '%SQ%'  -- row cache lock (SQ)
   OR  event LIKE '%enq: SQ%'
ORDER BY time_waited_micro DESC;
```

<details>
<summary>📌 Sequence 경합 심층 분석</summary>

```sql
-- row cache lock 관련 Sequence 경합 분석
SELECT ash.event, 
       ash.p1text, ash.p1, 
       ash.p2text, ash.p2,
       ash.current_obj#,
       COUNT(*) AS wait_count,
       ROUND(AVG(ash.time_waited)/1e3, 2) AS avg_wait_ms
FROM   gv$active_session_history ash
WHERE  ash.event = 'row cache lock'
AND    ash.sample_time > SYSDATE - INTERVAL '1' HOUR
GROUP BY ash.event, ash.p1text, ash.p1, ash.p2text, ash.p2, ash.current_obj#
ORDER BY wait_count DESC;

-- Instance별 Sequence 캐시 현황
SELECT inst_id, sequence_owner, sequence_name,
       cache_size, last_number
FROM   gv$_sequences_cache  -- (내부 뷰, 버전에 따라 다를 수 있음)
ORDER BY inst_id, sequence_owner, sequence_name;

-- NOORDER Sequence 사용 시 각 인스턴스 번호 범위 예시:
-- Instance 1: 1~5000, 10001~15000, ...
-- Instance 2: 5001~10000, 15001~20000, ...
-- → 순서는 보장 안 되지만 경합 없음
```

</details>

### 6.2 Reverse Key Index

**Right-hand Insert** 문제: 순차적 값(Sequence, 날짜)으로 인덱스에 INSERT 하면, 모든 인스턴스가 인덱스의 **가장 오른쪽 리프 블록**에 몰리면서 `gc buffer busy` 경합이 발생한다.

```
일반 B-Tree Index (Right-hand Insert 문제):
                    [Root]
                   /      \
            [Branch]     [Branch]
           /    \        /    \
      [Leaf1] [Leaf2] [Leaf3] [Leaf4] ← 모든 INSERT 집중!
                                        gc buffer busy 폭증

Reverse Key Index (분산 효과):
                    [Root]
                   /      \
            [Branch]     [Branch]
           /    \        /    \
      [Leaf1] [Leaf2] [Leaf3] [Leaf4]
         ↑       ↑       ↑       ↑
        INSERT가 리프 전체에 분산됨
```

```sql
-- Reverse Key Index 생성
CREATE INDEX idx_orders_id ON orders(order_id) REVERSE;

-- 기존 인덱스를 Reverse로 변환
ALTER INDEX idx_orders_id REBUILD REVERSE;

-- 다시 일반 인덱스로 되돌리기
ALTER INDEX idx_orders_id REBUILD NOREVERSE;
```

| 구분 | 일반 Index | Reverse Key Index |
|------|-----------|-------------------|
| Range Scan | ✅ 가능 | ❌ 불가 |
| Unique Scan | ✅ 가능 | ✅ 가능 |
| INSERT 분산 | ❌ Right-hand 집중 | ✅ 리프 전체 분산 |
| RAC 경합 | 높음 | 낮음 |

> ⚠️ **주의**  
> Reverse Key Index는 **Range Scan이 불가능**하다. `BETWEEN`, `>`, `<` 조건의 쿼리가 있는 컬럼에는 사용하지 말 것. 대안으로 **Hash Partitioned Index**를 고려하자.

### 6.3 ASSM vs MSSM in RAC

| 구분 | ASSM (권장) | MSSM |
|------|------------|------|
| 공간 관리 | Bitmap 기반 자동 | Freelist 기반 수동 |
| RAC 경합 | **낮음** (비트맵 분산) | **높음** (Freelist 단일 진입점) |
| INSERT 분산 | 자동으로 다른 블록 할당 | Freelist Groups 수동 설정 필요 |
| 권장 | ✅ Oracle 19c 기본값 | ❌ 레거시 |

```sql
-- 테이블스페이스 세그먼트 관리 방식 확인
SELECT tablespace_name, segment_space_management
FROM   dba_tablespaces
WHERE  contents = 'PERMANENT';

-- MSSM → ASSM 전환 (테이블스페이스 재생성 필요)
-- CREATE TABLESPACE ts_new
--   DATAFILE '+DATA' SIZE 10G
--   SEGMENT SPACE MANAGEMENT AUTO;  -- ASSM
```

> 💡 **실무 팁**  
> RAC 환경에서 Sequence 기반 PK의 INSERT 경합이 심하면, 다음 순서로 시도하자:  
> ① Sequence CACHE를 5000~10000으로 증가 + NOORDER  
> ② 그래도 경합이면 Reverse Key Index 적용  
> ③ 최후 수단: Hash Partitioned Table + Local Index

---

## 🔷 Section 07. Undo 및 Temp 튜닝

### 7.1 Instance별 UNDO Tablespace 전략

RAC에서 각 인스턴스는 **반드시 별도의 UNDO Tablespace**를 사용해야 한다.

```sql
-- Instance별 UNDO Tablespace 확인
SELECT inst_id, instance_name, 
       (SELECT value FROM gv$parameter p 
        WHERE p.inst_id = i.inst_id AND p.name = 'undo_tablespace') AS undo_ts
FROM   gv$instance i;

-- UNDO Tablespace 생성 (인스턴스별)
CREATE UNDO TABLESPACE UNDOTBS1 DATAFILE '+DATA' SIZE 10G AUTOEXTEND ON MAXSIZE 30G;
CREATE UNDO TABLESPACE UNDOTBS2 DATAFILE '+DATA' SIZE 10G AUTOEXTEND ON MAXSIZE 30G;

-- 인스턴스별 UNDO 할당 (spfile)
ALTER SYSTEM SET undo_tablespace = 'UNDOTBS1' SCOPE=SPFILE SID='PROD1';
ALTER SYSTEM SET undo_tablespace = 'UNDOTBS2' SCOPE=SPFILE SID='PROD2';
```

### 7.2 UNDO 관련 RAC 경합

Instance 1에서 Instance 2의 변경 데이터에 대한 **CR 블록을 구성**하려면, Instance 2의 UNDO 정보를 읽어야 한다. 이것이 **Cross-Instance UNDO 읽기**이며 RAC 고유의 오버헤드다.

```
Instance 1 (SELECT)                Instance 2 (UPDATE)
     │                                   │
     │  테이블 블록의 CR 버전 필요         │
     │  → Inst2의 UNDO 블록 필요          │
     │                                    │
     │──── gc cr request (UNDO block) ───►│
     │◄─── gc cr block 전송 ──────────────│
     │                                    │
  [CR 블록 구성 완료]                     │
```

```sql
-- Cross-Instance UNDO 읽기 현황
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name IN ('cr blocks served', 
                'current blocks served',
                'data blocks consistent reads - undo records applied')
ORDER BY inst_id, name;

-- UNDO Segment 경합 확인
SELECT inst_id, usn, undoblocksdone, undotsn,
       extents, writes, gets, waits
FROM   gv$rollstat
ORDER BY inst_id, waits DESC;
```

### 7.3 Temp Tablespace 분리

```sql
-- Instance별 Temp Tablespace 분리 (선택적)
CREATE TEMPORARY TABLESPACE TEMP1 
  TEMPFILE '+DATA' SIZE 5G AUTOEXTEND ON MAXSIZE 20G;
CREATE TEMPORARY TABLESPACE TEMP2 
  TEMPFILE '+DATA' SIZE 5G AUTOEXTEND ON MAXSIZE 20G;

-- Temp Tablespace Group 사용 (권장)
CREATE TEMPORARY TABLESPACE TEMP1 
  TEMPFILE '+DATA' SIZE 5G 
  TABLESPACE GROUP temp_grp;
CREATE TEMPORARY TABLESPACE TEMP2 
  TEMPFILE '+DATA' SIZE 5G 
  TABLESPACE GROUP temp_grp;

-- Default Temp를 그룹으로 지정
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE temp_grp;

-- Temp 사용량 모니터링
SELECT inst_id, tablespace_name,
       ROUND(tablespace_size * 8192 / 1024/1024, 2) AS total_mb,
       ROUND(allocated_space * 8192 / 1024/1024, 2) AS alloc_mb,
       ROUND(free_space * 8192 / 1024/1024, 2) AS free_mb
FROM   gv$temp_space_header
ORDER BY inst_id;
```

### 7.4 cr block 관련 UNDO 읽기 최소화

| 전략 | 설명 | 효과 |
|------|------|------|
| 워크로드 분리 | 같은 데이터에 대한 DML/SELECT를 같은 인스턴스에서 | Cross-Instance UNDO 읽기 제거 |
| UNDO_RETENTION 증가 | UNDO 보관 시간 충분히 확보 | ORA-01555 방지 |
| Flashback Data Archive | 장기간 UNDO 보관 | 이력 조회 시 UNDO 의존 제거 |

```sql
-- UNDO_RETENTION 설정 (인스턴스별)
ALTER SYSTEM SET undo_retention = 3600 SCOPE=BOTH SID='*';

-- UNDO 사용률 확인
SELECT inst_id,
       ROUND(undoblks * 8192 / 1024/1024, 2) AS undo_mb,
       txncount,
       maxquerylen
FROM   gv$undostat
WHERE  begin_time > SYSDATE - INTERVAL '1' HOUR
ORDER BY inst_id, begin_time DESC;
```

> 💡 **실무 팁**  
> RAC에서 대량 배치 작업을 수행하는 인스턴스와 온라인 조회를 하는 인스턴스를 분리하면, **Cross-Instance UNDO 읽기를 최소화**할 수 있다. 이것만으로도 gc cr 관련 대기가 30~50% 줄어든다.

---

## 🔷 Section 08. RAC 환경 SQL 튜닝

### 8.1 SQL Plan 안정화

RAC 환경에서는 **인스턴스별로 다른 실행 계획**이 선택될 수 있다. 통계 정보, 시스템 부하, 메모리 상태가 인스턴스마다 다르기 때문이다.

```sql
-- 인스턴스별 SQL 실행 계획 비교
SELECT inst_id, sql_id, plan_hash_value, 
       executions, elapsed_time,
       ROUND(elapsed_time/NULLIF(executions,0)/1e3, 2) AS avg_ms
FROM   gv$sql
WHERE  sql_id = '&sql_id'
ORDER BY inst_id;

-- SQL Plan Baseline으로 계획 고정
-- 1) 좋은 계획이 있는 인스턴스에서 캡처
DECLARE
  l_plans PLS_INTEGER;
BEGIN
  l_plans := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(
    sql_id => '&sql_id',
    plan_hash_value => &good_plan_hash
  );
  DBMS_OUTPUT.PUT_LINE('Loaded plans: ' || l_plans);
END;
/

-- 2) Baseline 확인
SELECT sql_handle, plan_name, enabled, accepted, fixed,
       optimizer_cost, elapsed_time
FROM   dba_sql_plan_baselines
WHERE  sql_text LIKE '%&keyword%';

-- 3) 계획 고정 (FIXED)
DECLARE
  l_plans PLS_INTEGER;
BEGIN
  l_plans := DBMS_SPM.ALTER_SQL_PLAN_BASELINE(
    sql_handle => '&sql_handle',
    plan_name  => '&plan_name',
    attribute_name => 'FIXED',
    attribute_value => 'YES'
  );
END;
/
```

### 8.2 Parallel Query in RAC

```sql
-- PARALLEL_FORCE_LOCAL: 로컬 인스턴스에서만 Parallel 실행
ALTER SYSTEM SET parallel_force_local = TRUE SCOPE=BOTH SID='*';
```

| 파라미터 | 설명 | RAC 권장 |
|---------|------|---------|
| `PARALLEL_FORCE_LOCAL` | Parallel Slave를 로컬 인스턴스에서만 사용 | ✅ TRUE |
| `PARALLEL_DEGREE_POLICY` | DOP 결정 정책 | AUTO 또는 MANUAL |
| `PARALLEL_MAX_SERVERS` | 인스턴스당 최대 PX 서버 수 | CPU * 2 이하 |
| `PARALLEL_ADAPTIVE_MULTI_USER` | 부하에 따른 DOP 자동 조절 | TRUE |

```
Inter-Instance Parallel (PARALLEL_FORCE_LOCAL = FALSE):
┌────────────┐    Interconnect    ┌────────────┐
│ Instance 1 │◄──────────────────►│ Instance 2 │
│ QC(Query   │  대량 데이터 전송!  │ PX Slave   │
│ Coordinator│  gc 경합 + 네트워크│ PX Slave   │
│ PX Slave   │  오버헤드 발생     │ PX Slave   │
│ PX Slave   │                    │            │
└────────────┘                    └────────────┘

Local Parallel (PARALLEL_FORCE_LOCAL = TRUE):
┌────────────┐                    ┌────────────┐
│ Instance 1 │                    │ Instance 2 │
│ QC         │  Interconnect     │ (관여 안 함)│
│ PX Slave   │  사용 안 함!       │            │
│ PX Slave   │                    │            │
│ PX Slave   │                    │            │
│ PX Slave   │                    │            │
└────────────┘                    └────────────┘
```

> ⚠️ **주의**  
> `PARALLEL_FORCE_LOCAL = TRUE`로 설정하면 **인스턴스 간 Parallel이 완전히 차단**된다. 단일 인스턴스의 CPU가 부족한 대규모 배치에서는 오히려 성능이 저하될 수 있으므로, **Service 단위로** 설정하는 것이 좋다.

### 8.3 Full Table Scan vs Index Scan (RAC에서의 차이)

| 접근 방식 | Single Instance | RAC |
|----------|----------------|-----|
| Full Table Scan | Direct Path Read → 빠름 | **인스턴스 간 블록 공유 문제 없음** (Direct Path) |
| Index Range Scan | Buffer Cache Hit | **gc 경합 가능** (Buffer Cache 의존) |
| Index Unique Scan | Buffer Cache Hit | gc 경합 낮음 (단일 블록) |

```sql
-- RAC에서 Direct Path Read 강제 (대형 테이블)
ALTER SESSION SET "_serial_direct_read" = TRUE;

-- 또는 테이블 레벨 설정
ALTER TABLE large_table STORAGE (CELL_FLASH_CACHE NONE);  -- Exadata
-- 11g 이상에서는 _small_table_threshold 기반 자동 판단

-- Full Table Scan 시 gc 이벤트 발생 여부 확인
SELECT event, COUNT(*) AS cnt
FROM   gv$active_session_history
WHERE  sql_id = '&sql_id'
AND    event LIKE 'gc%'
GROUP BY event
ORDER BY cnt DESC;
```

> 💡 **실무 팁**  
> RAC에서 **대형 테이블의 Full Table Scan은 의외로 성능이 좋을 수 있다**. Direct Path Read로 처리되면 Buffer Cache를 거치지 않아 gc 경합이 없기 때문이다. 반면 Index Scan은 Buffer Cache를 통해 gc 경합을 유발할 수 있으므로, RAC에서는 실행 계획 선택 시 이 점을 고려하자.

<details>
<summary>📌 RAC SQL 튜닝 체크리스트</summary>

```
✅ RAC SQL 튜닝 체크리스트

□ 1. SQL Plan이 인스턴스별로 동일한가?
    → gv$sql에서 plan_hash_value 비교
    → 다르면 SQL Plan Baseline으로 고정

□ 2. gc 관련 Wait가 SQL 수행 시간의 30% 이상인가?
    → ASH에서 해당 sql_id의 이벤트 분포 확인
    → gc 비중 높으면 워크로드 분리 또는 SQL 튜닝

□ 3. Parallel Query가 Inter-Instance로 실행되는가?
    → PARALLEL_FORCE_LOCAL = TRUE 검토
    → V$PQ_SESSTAT에서 서버 분포 확인

□ 4. 핫 블록에 대한 반복 접근이 있는가?
    → ASH current_obj#, current_block# 분석
    → 파티셔닝 또는 인덱스 재구성

□ 5. Full Table Scan이 Buffer Cache를 경유하는가?
    → _serial_direct_read 확인
    → _small_table_threshold 조정
```

</details>

---

## 🔷 Section 09. AWR/ASH/ADDM RAC 분석

### 9.1 RAC 전용 AWR 섹션

AWR Report에는 RAC 환경에서만 나타나는 전용 섹션이 있다.

| AWR 섹션 | 내용 | 핵심 지표 |
|----------|------|----------|
| RAC Statistics | 인스턴스 간 블록 전송 통계 | gc blocks received/served |
| Global Cache Load Profile | 초당 gc 블록 전송량 | gc blocks received per second |
| Global Cache Efficiency | Cache Fusion 효율 | Buffer access - local% |
| Global Cache Transfer Stats | 전송 시간별 분포 | avg cr/current block receive time |
| Interconnect Ping Latency | 노드 간 지연 시간 | 500B/8K ping time |
| Global Enqueue Stats | 글로벌 Lock 통계 | enqueue gets/converts/releases |
| Dynamic Remastering Stats | DRM 활동 통계 | remaster ops, affinity objects |

```sql
-- AWR Report 생성 (RAC 전용: Global)
-- 단일 인스턴스 AWR
@$ORACLE_HOME/rdbms/admin/awrrpt.sql

-- Global AWR (모든 인스턴스 통합)
@$ORACLE_HOME/rdbms/admin/awrgrpt.sql

-- 특정 인스턴스 비교 AWR
@$ORACLE_HOME/rdbms/admin/awrddrpt.sql  -- Diff Report
```

### 9.2 Global AWR Report 핵심 분석

```sql
-- Global AWR Report에서 확인해야 할 핵심 수치

-- 1. Global Cache Efficiency
SELECT inst_id,
       ROUND(SUM(CASE WHEN name = 'gc cr blocks received' THEN value END) /
             NULLIF(SUM(CASE WHEN name = 'consistent gets' THEN value END), 0) * 100, 2) 
       AS pct_cr_from_remote
FROM   gv$sysstat
WHERE  name IN ('gc cr blocks received', 'consistent gets')
GROUP BY inst_id;
-- pct_cr_from_remote > 10% 이면 워크로드 분리 필요

-- 2. Avg gc block receive time (ms)
SELECT inst_id,
       ROUND(gc_cr_block_receive_time / NULLIF(gc_cr_blocks_received, 0) * 10, 2) AS avg_cr_ms,
       ROUND(gc_current_block_receive_time / NULLIF(gc_current_blocks_received, 0) * 10, 2) AS avg_cur_ms
FROM (
  SELECT inst_id,
         SUM(CASE WHEN name = 'gc cr block receive time' THEN value END) AS gc_cr_block_receive_time,
         SUM(CASE WHEN name = 'gc cr blocks received' THEN value END) AS gc_cr_blocks_received,
         SUM(CASE WHEN name = 'gc current block receive time' THEN value END) AS gc_current_block_receive_time,
         SUM(CASE WHEN name = 'gc current blocks received' THEN value END) AS gc_current_blocks_received
  FROM   gv$sysstat
  WHERE  name IN ('gc cr block receive time', 'gc cr blocks received',
                  'gc current block receive time', 'gc current blocks received')
  GROUP BY inst_id
);
-- avg_cr_ms, avg_cur_ms < 1ms : 우수
-- 1~3ms : 양호
-- > 3ms : Interconnect 점검 필요
```

### 9.3 ASH에서 Instance별 분석

```sql
-- Instance별 Top Wait Event 비교 (최근 1시간)
SELECT instance_number, event,
       COUNT(*) AS sample_count,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY instance_number), 2) AS pct
FROM   gv$active_session_history
WHERE  sample_time > SYSDATE - INTERVAL '1' HOUR
AND    event IS NOT NULL
GROUP BY instance_number, event
ORDER BY instance_number, sample_count DESC
FETCH FIRST 20 ROWS ONLY;

-- 특정 시간대의 gc 경합 발생 세션 추적
SELECT sample_time, instance_number, session_id, sql_id,
       event, current_obj#, current_file#, current_block#,
       blocking_inst_id, blocking_session
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN 
       TO_TIMESTAMP('2026-03-23 14:00:00', 'YYYY-MM-DD HH24:MI:SS') AND
       TO_TIMESTAMP('2026-03-23 15:00:00', 'YYYY-MM-DD HH24:MI:SS')
AND    event LIKE 'gc%'
ORDER BY sample_time;

-- Instance 간 블록 전송 패턴 분석
SELECT instance_number AS requester_inst,
       blocking_inst_id AS holder_inst,
       event,
       COUNT(*) AS cnt
FROM   dba_hist_active_sess_history
WHERE  sample_time > SYSDATE - INTERVAL '1' DAY
AND    event LIKE 'gc%'
AND    blocking_inst_id IS NOT NULL
GROUP BY instance_number, blocking_inst_id, event
ORDER BY cnt DESC;
```

### 9.4 ADDM RAC 권고사항

```sql
-- ADDM RAC 분석 실행
-- Instance 레벨 ADDM
@$ORACLE_HOME/rdbms/admin/addmrpt.sql

-- Database 레벨 ADDM (RAC 전체 분석)
-- ADDM은 자동으로 RAC 관련 이슈를 탐지:
-- - Interconnect 병목
-- - 과도한 gc 경합
-- - 워크로드 불균형
-- - Sequence/Index Contention

-- ADDM 결과 조회
SELECT dbid, task_id, task_name, 
       finding_name, impact, message
FROM   dba_advisor_findings
WHERE  task_name LIKE 'ADDM%'
AND    impact > 0
ORDER BY impact DESC
FETCH FIRST 20 ROWS ONLY;

-- ADDM 권고사항 조회
SELECT task_id, rec_id, type, benefit,
       action_message
FROM   dba_advisor_recommendations r,
       dba_advisor_actions a
WHERE  r.task_id = a.task_id
AND    r.rec_id = a.rec_id
AND    r.task_name LIKE 'ADDM%'
ORDER BY benefit DESC;
```

<details>
<summary>📌 RAC AWR 종합 분석 스크립트</summary>

```sql
-- RAC Health Check 종합 쿼리
SET PAGESIZE 200 LINESIZE 200

PROMPT ============================================
PROMPT   1. RAC 기본 정보
PROMPT ============================================
SELECT inst_id, instance_name, host_name, version, status,
       TO_CHAR(startup_time, 'YYYY-MM-DD HH24:MI:SS') AS startup
FROM   gv$instance
ORDER BY inst_id;

PROMPT ============================================
PROMPT   2. Interconnect 정보
PROMPT ============================================
SELECT inst_id, name, ip_address, is_public, source
FROM   gv$cluster_interconnects
ORDER BY inst_id;

PROMPT ============================================
PROMPT   3. gc 블록 전송 효율
PROMPT ============================================
SELECT a.inst_id,
       ROUND(a.value * 10 / NULLIF(b.value, 0), 2) AS avg_cr_receive_ms,
       ROUND(c.value * 10 / NULLIF(d.value, 0), 2) AS avg_cur_receive_ms
FROM   gv$sysstat a, gv$sysstat b, gv$sysstat c, gv$sysstat d
WHERE  a.inst_id = b.inst_id AND b.inst_id = c.inst_id AND c.inst_id = d.inst_id
AND    a.name = 'gc cr block receive time'
AND    b.name = 'gc cr blocks received'
AND    c.name = 'gc current block receive time'
AND    d.name = 'gc current blocks received';

PROMPT ============================================
PROMPT   4. Top gc Wait Events
PROMPT ============================================
SELECT inst_id, event, total_waits,
       ROUND(time_waited_micro/1e6, 2) AS time_sec,
       ROUND(average_wait_micro/1e3, 2) AS avg_ms
FROM   gv$system_event
WHERE  wait_class = 'Cluster'
ORDER BY time_waited_micro DESC
FETCH FIRST 15 ROWS ONLY;

PROMPT ============================================
PROMPT   5. gc blocks lost (패킷 유실)
PROMPT ============================================
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name LIKE '%lost%'
AND    name LIKE '%gc%'
ORDER BY inst_id;

PROMPT ============================================
PROMPT   6. DRM Remastering 현황
PROMPT ============================================
SELECT inst_id, remaster_ops, remaster_time,
       current_objects, quiesce_time
FROM   gv$dynamic_remaster_stats;

PROMPT ============================================
PROMPT   7. Sequence 캐시 점검
PROMPT ============================================
SELECT sequence_owner, sequence_name, cache_size, order_flag
FROM   dba_sequences
WHERE  cache_size < 100
AND    sequence_owner NOT IN ('SYS','SYSTEM','XDB','MDSYS')
ORDER BY cache_size;
```

</details>

> 💡 **실무 팁**  
> RAC 성능 분석 시 **반드시 Global AWR Report를 먼저** 확인하자. Instance 레벨 AWR만 보면 한쪽 인스턴스의 문제가 보이지 않을 수 있다. `awrgrpt.sql`로 생성하면 모든 인스턴스의 통합 뷰를 볼 수 있다.

---

## 🔷 Section 10. 실전 트러블슈팅 사례

### 사례 1: gc buffer busy 폭증 → Interconnect 병목

#### 상황
- 오전 10시 이후 OLTP 응답 시간이 3배 증가
- AWR Top Wait: `gc buffer busy acquire` (전체 DB Time의 45%)

#### 분석

```sql
-- Step 1: gc buffer busy 평균 대기 시간 확인
SELECT event, total_waits,
       ROUND(average_wait_micro/1e3, 2) AS avg_ms
FROM   gv$system_event
WHERE  event LIKE 'gc buffer busy%';
-- 결과: avg_ms = 15ms (정상은 < 1ms)

-- Step 2: Interconnect 전송 시간 확인
SELECT event, ROUND(average_wait_micro/1e3, 2) AS avg_ms
FROM   gv$system_event
WHERE  event IN ('gc cr block 2-way', 'gc current block 2-way');
-- 결과: avg_ms = 8ms (정상은 < 1ms) → Interconnect 문제!

-- Step 3: gc blocks lost 확인
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name LIKE 'gc%lost%';
-- 결과: gc blocks lost = 15,234 → 패킷 유실!
```

#### 원인
- 네트워크 스위치 펌웨어 버그로 인한 **패킷 드롭**
- Interconnect NIC의 에러 카운터 증가 확인

```bash
# OS에서 NIC 에러 확인
ethtool -S eth1 | grep -i error
# rx_errors: 12,450
# tx_errors: 0
# rx_crc_errors: 11,890  ← CRC 에러 다수!
```

#### 해결

```bash
# 1. 스위치 펌웨어 업데이트
# 2. NIC 교체 후 정상화
# 3. Bonding으로 이중화 구성
nmcli connection add type bond con-name bond0 ifname bond0 mode 802.3ad
nmcli connection add type ethernet con-name bond0-slave1 ifname eth1 master bond0
nmcli connection add type ethernet con-name bond0-slave2 ifname eth2 master bond0
```

> 💡 **실무 팁**  
> `gc blocks lost > 0`이면 **가장 먼저 OS 레벨에서 NIC 에러를 확인**하자. `ethtool -S`, `ip -s link show`, `netstat -i` 등으로 확인할 수 있다. CRC 에러가 발생하면 케이블, NIC, 스위치 포트를 순서대로 점검한다.

---

### 사례 2: Sequence Contention으로 Insert 성능 저하

#### 상황
- 주문 테이블 INSERT 성능이 RAC 이관 후 5배 저하
- AWR Top Wait: `row cache lock` + `gc current block busy`

#### 분석

```sql
-- Step 1: Sequence 설정 확인
SELECT sequence_name, cache_size, order_flag
FROM   dba_sequences
WHERE  sequence_name = 'ORDER_SEQ';
-- 결과: CACHE 20, ORDER → 심각한 경합!

-- Step 2: row cache lock 대기 확인
SELECT event, total_waits,
       ROUND(time_waited_micro/1e6, 2) AS time_sec
FROM   gv$system_event
WHERE  event = 'row cache lock';
-- 결과: 50만 건/시간 대기

-- Step 3: 핫 블록 확인 (인덱스 Right-hand Insert)
SELECT current_obj#, current_block#, COUNT(*) AS cnt
FROM   gv$active_session_history
WHERE  event = 'gc current block busy'
AND    sample_time > SYSDATE - INTERVAL '1' HOUR
GROUP BY current_obj#, current_block#
ORDER BY cnt DESC;
-- 결과: ORDER_PK 인덱스의 마지막 리프 블록에 집중
```

#### 해결

```sql
-- 1. Sequence Cache 확대 + NOORDER
ALTER SEQUENCE order_seq CACHE 10000 NOORDER;

-- 2. PK Index를 Reverse Key로 변환
ALTER INDEX order_pk REBUILD REVERSE ONLINE;

-- 결과: row cache lock 99% 감소, gc current block busy 95% 감소
-- INSERT TPS: 1,200 → 8,500
```

---

### 사례 3: Cross-Instance Deadlock 해결

#### 상황
- 간헐적으로 ORA-00060 (Deadlock) 발생
- Alert Log에 Deadlock Graph 확인 시 **서로 다른 인스턴스**의 세션이 관여

#### 분석

```sql
-- Alert Log에서 Deadlock Graph 확인
-- Deadlock graph:
--  ---------Blocker(s)--------  ---------Waiter(s)---------
--  Resource Name  process session inst Resource Name  process session inst
--  TX-00180025-... 45     234     1   TX-000A0012-... 67     456     2
--  TX-000A0012-... 67     456     2   TX-00180025-... 45     234     1

-- Cross-Instance Deadlock 이력 조회
SELECT * FROM gv$deadlock_info;  -- 12c 이상

-- ASH에서 Deadlock 시점의 세션 활동 추적
SELECT sample_time, instance_number, session_id, sql_id,
       event, blocking_inst_id, blocking_session
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN 
       TO_TIMESTAMP('2026-03-22 14:55:00', 'YYYY-MM-DD HH24:MI:SS') AND
       TO_TIMESTAMP('2026-03-22 15:05:00', 'YYYY-MM-DD HH24:MI:SS')
AND    event LIKE 'enq: TX%'
ORDER BY sample_time;
```

#### 원인
- 두 애플리케이션이 **서로 다른 순서로** 테이블 업데이트
- App A (Inst1): UPDATE orders → UPDATE inventory
- App B (Inst2): UPDATE inventory → UPDATE orders

#### 해결

```sql
-- 1. 애플리케이션에서 테이블 접근 순서 통일
-- App A & B 모두: UPDATE inventory → UPDATE orders (알파벳 순)

-- 2. 같은 테이블 조합은 같은 인스턴스에서 처리 (Service 분리)
-- $ srvctl add service -db PRODDB -service SVC_ORDER_MGMT \
--   -preferred PROD1 -available PROD2

-- 3. Row-level Lock 최소화 (SELECT FOR UPDATE WAIT 사용)
SELECT * FROM orders WHERE order_id = :id FOR UPDATE WAIT 3;
-- 3초 안에 락 획득 못하면 즉시 실패 → 빠른 재시도
```

---

### 사례 4: 인스턴스 Eviction과 Recovery 성능

#### 상황
- Instance 2가 갑자기 Eviction (강제 퇴출)
- Instance 1에서 Recovery 완료까지 15분 소요 → 서비스 영향

#### 분석

```sql
-- Eviction 원인 확인 (Alert Log, CSS Log)
-- $ grep -i "evict\|split\|reconfiguration" $ORACLE_BASE/diag/crs/*/crs/trace/ocssd.trc

-- Instance Recovery 진행 상태
SELECT inst_id, recovery_estimated_ios, actual_redo_blks, 
       target_redo_blks
FROM   gv$instance_recovery;

-- Instance Recovery 시간에 영향을 주는 요소
SELECT inst_id, name, value
FROM   gv$parameter
WHERE  name IN ('fast_start_mttr_target', 
                'log_checkpoint_interval',
                'log_checkpoint_timeout');
```

#### 원인과 해결

```sql
-- 1. Eviction 원인: Interconnect 일시 장애 → CSS가 heartbeat 실패로 판단
-- 해결: CSS misscount 늘림 (기본 30초 → 60초)
-- $ crsctl set css misscount 60

-- 2. Recovery 시간 단축: FAST_START_MTTR_TARGET 설정
ALTER SYSTEM SET fast_start_mttr_target = 30 SCOPE=BOTH SID='*';
-- → 체크포인트 빈도 증가 → Recovery 시 적용할 Redo 감소 → 빠른 복구

-- 3. Redo Log 크기 최적화
-- Redo Log가 너무 크면 Recovery 시 적용할 Redo가 많아짐
-- Instance당 3~4개 그룹, 각 500MB~1GB 권장
ALTER DATABASE ADD LOGFILE INSTANCE 'PROD2' 
  GROUP 5 ('+DATA','+FRA') SIZE 1G;
```

<details>
<summary>📌 RAC Eviction 예방 체크리스트</summary>

```
✅ RAC Eviction 예방 체크리스트

□ Interconnect NIC Bonding (이중화)
  → 한 NIC 장애 시에도 CSS heartbeat 유지

□ CSS misscount 적절히 설정 (기본 30초)
  → 네트워크 일시 장애가 잦으면 60초로 증가
  → 너무 크게 설정하면 실제 장애 감지 지연

□ Voting Disk 접근성 확보
  → ASM Disk Group에 Voting Disk 3개 이상
  → 과반수 접근 가능해야 함

□ OS 레벨 hang 방지
  → hugepages 설정 (swap out 방지)
  → vm.min_free_kbytes 적절히 설정
  → 메모리 과다 할당 금지

□ FAST_START_MTTR_TARGET 설정
  → Recovery 시간 목표 설정 (30~60초 권장)

□ 정기적인 Interconnect 헬스체크
  → NIC 에러 카운터 모니터링
  → 스위치 포트 에러 확인
  → ping latency 추이 모니터링
```

</details>

> ⚠️ **주의**  
> `css misscount`를 너무 크게 설정하면 **실제 장애 시 감지가 늦어진다**. 60초를 초과하는 설정은 권장하지 않는다. 근본 원인(네트워크 불안정)을 해결하는 것이 우선이다.

---

## 📋 RAC 성능 튜닝 종합 체크리스트

| 영역 | 점검 항목 | 권장 설정/조치 |
|------|----------|---------------|
| Interconnect | 대역폭 | 10GbE 이상, 권장 25GbE |
| Interconnect | Jumbo Frame | MTU 9000 (전 구간) |
| Interconnect | NIC Bonding | Active-Active (LACP) |
| Interconnect | gc blocks lost | 0이어야 함 |
| Cache Fusion | avg gc block receive time | < 1ms |
| Cache Fusion | DRM | 기본값 유지, 문제 시 비활성화 검토 |
| 워크로드 | Service 분리 | OLTP/Batch/Report 분리 필수 |
| 워크로드 | CLB/RLB | CLB_GOAL + RLB_GOAL 설정 |
| Sequence | Cache Size | 5000~10000 + NOORDER |
| Index | Right-hand Insert | Reverse Key 또는 Hash Partition |
| 세그먼트 | 공간 관리 | ASSM 필수 |
| UNDO | Tablespace | 인스턴스별 분리 |
| Parallel | PARALLEL_FORCE_LOCAL | TRUE (OLTP 서비스) |
| SQL Plan | Plan 안정화 | SQL Plan Baseline 사용 |
| Recovery | FAST_START_MTTR_TARGET | 30~60초 |
| 모니터링 | AWR | Global AWR 정기 수집 |

---

> 📌 **이 문서는 Oracle 19c RAC 환경을 기준으로 작성되었습니다.**  
> 버전에 따라 파라미터, 뷰 이름, 기능이 다를 수 있으므로 공식 문서를 참조하세요.

---

[🔼 목차로 돌아가기](#-목차)
