-- =============================================================================
-- Part 19 정리 스크립트
-- 목적: 모든 테스트 테이블 삭제 및 휴지통 정리
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON

PROMPT
PROMPT ========================================
PROMPT Part 19 테스트 환경 정리 시작
PROMPT ========================================

-- 공통 데이터 세트 테이블 삭제
BEGIN
    FOR rec IN (SELECT table_name FROM user_tables WHERE table_name IN (
        'T_CUSTOMER', 'T_ORDER', 'T_ORDER_DETAIL', 'T_PRODUCT', 'T_CATEGORY',
        'T_CODE', 'T_STORE', 'T_LOG', 'T_BOARD', 'T_DEPT', 'T_STATUS', 'T_DAILY_SALES'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';
        DBMS_OUTPUT.PUT_LINE('Dropped: ' || rec.table_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN 
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

-- 기존 case별 개별 테이블들도 정리 (혹시 남아있을 경우)
BEGIN
    FOR rec IN (SELECT table_name FROM user_tables WHERE table_name IN (
        -- case_01 테이블들
        '외화수표일별', '외화수표매입',
        -- case_02 테이블들  
        '카드환불내역',
        -- case_03 테이블들
        '접수처리기본', '신청기본', '여신고객기본',
        -- case_04 테이블들
        'SCHEMA1_처리내역', 'SCHEMA2_처리내역', '메타기본',
        -- case_05 테이블들
        '청구서내역', '단순통합코드', '카드기본',
        -- case_06 테이블들
        '거래내역', '계좌기본', '고객정보',
        -- case_07 테이블들
        '경영체등록내역', '경영체종사원등록내역',
        -- case_08 테이블들
        '취급상품기본', '상품기본', '취급상품매출단가',
        -- case_09 테이블들
        '게시판관리', '게시판', '공통코드',
        -- case_10 테이블들
        '매출데이터', '고객기본정보', '상품정보',
        -- case_11 테이블들
        '계좌거래내역',
        -- case_12 테이블들
        '일자관리', '휴일관리',
        -- case_13 테이블들
        '주문내역', '고객마스터', '상품마스터',
        -- case_14 테이블들
        'TB_EQ_RT_RS', 'TB_EQQ_RT_RS', 'TB_PAR_ST_RS',
        -- case_15 테이블들
        'TB_RETURN_SLP', 'TB_RETURN_SHT',
        -- case_16 테이블들
        'TB_MA_HST', 'TB_LT_HST', 'TB_DES_INF'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';
        DBMS_OUTPUT.PUT_LINE('Dropped legacy: ' || rec.table_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

-- 휴지통 정리
PURGE RECYCLEBIN;

-- 남은 테이블 확인
PROMPT
PROMPT ========================================
PROMPT 현재 사용자 테이블 목록:
PROMPT ========================================

SELECT table_name, num_rows 
FROM user_tables 
ORDER BY table_name;

PROMPT
PROMPT ========================================
PROMPT 정리 완료!
PROMPT ========================================