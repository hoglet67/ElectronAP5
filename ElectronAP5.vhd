----------------------------------------------------------------------------------
-- Engineer:            David Hitchens and David Banks
--
-- Create Date:         10/4/2017
-- Module Name:         Electron AP5 CPLD
-- Project Name:        Electron AP5
-- Target Devices:      9572XL
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ElectronAP5 is
    Port (
        A:        in    std_logic_vector(13 downto 0);
        CLK16MHz: in    std_logic;
        nNMI1MHz: in    std_logic;
        nPFC:     in    std_logic;
        nPFD:     in    std_logic;
        nROE:     in    std_logic;
        nROM13:   in    std_logic;
        nRST:     in    std_logic;
        LKD02:    in    std_logic;
        LKD13:    in    std_logic;
        MMCM:     in    std_logic;
        Phi0:     in    std_logic;
        QA:       in    std_logic;
        R13256KS: in    std_logic;
        R13D:     in    std_logic;
        RnW:      in    std_logic;
        A14:      out   std_logic;
        B1MHz:    out   std_logic;
        BnPFC:    out   std_logic;
        BnPFD:    out   std_logic;
        BnRW:     out   std_logic;
        BRnW:     out   std_logic;
        BRnW13:   out   std_logic;
        DIRA:     out   std_logic;
        nCE13:    out   std_logic;
        nCE1:     out   std_logic;
        nCE2:     out   std_logic;
        nFCBx:    out   std_logic;
        NMID:     out   std_logic;
        nOE13:    out   std_logic;
        nOE1:     out   std_logic;
        nOE2:     out   std_logic;
        S1RnW:    out   std_logic;
        S2RnW:    out   std_logic;
        nSELA:    out   std_logic;
        nSELB:    out   std_logic;
        D:        inout std_logic_vector(7 downto 0)
    );
end ElectronAP5;

architecture Behavorial of ElectronAP5 is

signal BnPFC_int : std_logic;
signal BnPFD_int : std_logic;
signal nSELA_int : std_logic;

signal seenRst   : std_logic := '0';
signal nLoadIn   : std_logic;
signal nLoad     : std_logic := '1';
signal nLoadDash : std_logic := '1';
signal syncCount : unsigned(3 downto 0);

signal AEN       : std_logic := '0';
signal BEN       : std_logic := '0';

signal test      : std_logic_vector(7 downto 0);

begin

    -- =============================================
    -- Test Register
    -- =============================================

    -- Initialized on reset to 0xAA
    -- Read/Write at &FCD7
    
    process(Phi0)
    begin
        if falling_edge(Phi0) then
            if (nRST = '0') then
                test <= x"AA";
            elsif nPFC = '0' and RnW = '0' and A(7 downto 0) = x"D7" then
                test <= D;
            end if;
        end if;
    end process;

    -- Be conservative about bus conflicts by only driving when Phi0 is high
    D <= test when nPFC = '0' and RnW = '1' and A(7 downto 0) = x"D7" and Phi0 = '1' else
         "ZZZZZZZZ";

    -- =============================================
    -- 1MHz clock generation
    -- =============================================

    -- Note, the signal names and polarities don't quite match the
    -- schematic, as they have been ammended for clarity.

    -- seenRst goes active when nRST is asserted
    -- it stays active until nLoad loads the counter

    -- The original design used an RS flip/flop, but it's not good practice to use these in
    -- CPLDs, especially if they can be replaced with a synchronous alternative

    -- process(nLoad, nRST)
    -- begin
    --     if (nRST = '0') then
    --         seenRst <= '1';
    --     elsif (nLoad = '0') then
    --         seenRst <= '0';
    --     end if;
    -- end process;

    process(CLK16MHz)
    begin
        if falling_edge(CLK16MHZ) then
            if (nRST = '0') then
                seenRst <= '1';
            elsif (nLoad = '0') then
                seenRst <= '0';
            end if;
        end if;
    end process;

    -- start the synchronization process on the first tube read cycle after a reset
    nLoadIn <= '0' when seenRst = '1' and nSELA_int = '0' and RnW = '1' else '1';

    -- actually synchronize to the next falling edge of Phi0
    process(Phi0, nLoadDash)
    begin
        if (nLoadDash = '0') then
            nLoad <= '1';
        elsif falling_edge(Phi0) then
            nLoad <= nLoadIn;
        end if;
    end process;

    process(CLK16MHz)
    begin
        if rising_edge(CLK16MHZ) then
            if (nLoad = '0') then
                syncCount <= x"1";
            else
                syncCount <= syncCount + 1;
            end if;
            -- nLoadDash is just nLoad delayed by one 16MHz cycle
            nLoadDash <= nLoad;
        end if;
    end process;

    B1MHz <= syncCount(3);

    -- =============================================
    -- NMI
    -- =============================================
    --
    -- Synchronize NMI from the 1MHz bus with Phi0
    --
    -- NMID drives a transistor; high will assert NMI

    process(Phi0, nRST)
    begin
        if (nRST = '0') then
            NMID <= '0';
        elsif falling_edge(Phi0) then
            NMID <= nNMI1MHz;
        end if;
    end process;

    -- =============================================
    -- ROMs
    -- =============================================

    -- Software Write Enables for the two ROMs
    --
    -- In 16K Mode
    --   AEN enables write to ROM 0/2
    --   BEN enables write to ROM 1/3
    -- In 32K Mode
    --   AEN enables write to lower half of ROM 1/3
    --   BEN enables write to upper half of ROM 1/3
    -- These registers should power up to locked (0)
    --
    -- Write to &FCDC - Unlock ROM 0/2
    -- Write to &FCDD - Lock ROM 0/2
    -- Write to &FCDE - Unlock ROM 1/3
    -- Write to &FCDF - Lock ROM 1/3
    --
    -- If the lock disable (LKD) jumper is present (LKD = 0), then
    -- then disable the software lockking
    process(Phi0)
    begin
        if falling_edge(Phi0) then
            if LKD02 = '0' then
                -- lock disable jumper present
                AEN <= '1';
            else
                -- lock disable jumper absent
                if A(7 downto 0) = x"DC" and nPFC = '0' and RnW = '0' then
                    AEN <= '1';
                end if;
                if A(7 downto 0) = x"DD" and nPFC = '0' and RnW = '0' then
                    AEN <= '0';
                end if;
            end if;
            if LKD13 = '0' then
                -- lock disable jumper present
                BEN <= '1';
            else
                -- lock disable jumper absent
                if A(7 downto 0) = x"DE" and nPFC = '0' and RnW = '0' then
                    BEN <= '1';
                end if;
                if A(7 downto 0) = x"DF" and nPFC = '0' and RnW = '0' then
                    BEN <= '0';
                end if;
            end if;
        end if;
    end process;

    -- BnRW13 drives nWE of ROM13, and is a gated version of RnW
    BRnW13 <= '0' when RnW = '0' and Phi0 = '1' else '1';

    -- nCE13 drives nCE of ROM13, jumper on R13D disables this ROM
    nCE13 <= nROM13 when R13D = '1' else '1';

    -- nOE13 drives nOE of ROM13, disable during writes
    nOE13 <= not RnW;

    -- Summary of how ROM mapping is implemented
    --
    -- Note: The R13256KS and MMCM jumpers are effectively active low
    -- i.e. 0 = jumper fitted, 1 = jumper missing
    --
    -- Mode:            Inputs:                          Outputs:
    --                  Mode jumpers:   Address:  ROM:   nCE to   nCE to
    --                  R13256KS MMCM   A(13:0)   QA     ROM 0/2  ROM 1/3  A14
    -- normal/16K       1        1      *         0      0        1        1
    --                  1        1      *         1      1        0        1
    -- normal/32K       0        1      *         0      1        0        0
    --                  0        1      *         1      1        0        1
    -- MMC mode/32K     *        0      *         0      1        0        0
    --                  *        0      <  &3600  1      1        0        1
    --                  *        0      >= &3600  1      0        1        1

    -- S1RnW drives nWR of ROM 0/2
    S1RnW <=
        -- in normal mode, suport locking with AEN and gate with Phi2
        '0' when MMCM = '1' and RnW = '0' and AEN ='1' and Phi0 = '1' else
        -- in MMC mode, the RAM is not lockable as it's used for workspace
        '0' when MMCM = '0' and RnW = '0'              and Phi0 = '1' else
        -- default to no write
        '1';

    -- nOE1 drives nOE of ROM 0/2, always disable during writes
    nOE1 <= not RnW;

    -- nCE1 drives nCE of ROM 0/2
    nCE1 <=
        -- in normal mode, enable for even ROM only when the 256K jumper is not fitted
        '0' when MMCM = '1' and nROE = '0' and (QA = '0' and R13256KS = '1') else
        -- in MMC mode, enable for odd ROM accesses >= &B600
        '0' when MMCM = '0' and nROE = '0' and (QA = '1' and A(13 downto 8) >= "110110") else
        -- default to disabled
        '1';

    -- S2Rnw drives nWE of ROM 1/3
    S2Rnw <=
        -- in normal mode, lock based on AEN or BEN depending on the ROM size and bank
        '0' when MMCM = '1' and RnW = '0' and ((QA = '0' and R13256KS = '0' and AEN = '1') or BEN = '1') and Phi0 = '1' else
        -- in MMC mode, ignore the 256K jumper as the ROM 1/3 must be 32K
        '0' when MMCM = '0' and RnW = '0' and ((QA = '0'                    and AEN = '1') or BEN = '1') and Phi0 = '1' else
        -- default to no write
        '1';

    -- nOE2 drives nOE of ROM 1/3, always disable during writes
    nOE2 <= not RnW;

    -- nCE2 drives nCE of ROM 1/3
    nCE2 <=
        -- in normal mode, enable when 256K jumper is present, or for the odd ROM
        '0' when MMCM = '1' and nROE = '0' and (QA = '1' or R13256KS = '0') else
        -- in MMC mode, enable for the even ROM,
        '0' when MMCM = '0' and nROE = '0' and (QA = '0' or A(13 downto 8) < "110110") else
        -- default to disabled
        '1';

    -- A14 drives A14 input to ROM 1/3
    A14 <=
        -- in normal mode when 256K jumper is present, pass QA through as A14
        QA when MMCM = '1' and R13256KS = '0' else
        -- in MMC mode, ignore the 256K jumper as the ROM 1/3 must be 32K
        QA when MMCM = '0'                    else
        -- default to A14 = 1
        '1';

    -- =============================================
    -- Tube
    -- =============================================

    -- nSELA decodes address &FCEx
    nSELA_int <= '0' when nPFC = '0' and A(7 downto 4) = x"E" else '1';
    nSELA <= nSELA_int;

    -- DIRA is direction input to 74LS245A, A side to Tube, B side to Elk)
    -- 0: B->A; 1: A->B
    DIRA  <= '1' when nSELA_int = '0' and RnW = '1' else '0';

    -- =============================================
    -- 1MHZ Bus
    -- =============================================

    -- BnPFC decodes addresses &FC2x, &FC3x, &FC8x, &FCAx, &FCFx
    BnPFC_int <= '0' when nPFC = '0' and (
        A(7 downto 4) = x"2" or
        A(7 downto 4) = x"3" or
        A(7 downto 4) = x"8" or
        A(7 downto 4) = x"A" or
        A(7 downto 4) = x"F") else '1';
    BnPFC <= BnPFC_int;

    -- BnPFD decodes addresses &FDxx
    BnPFD_int <= nPFD;
    BnPFD <= BnPFD_int;

    -- nSELB is the enable input to LS245A, asserted for any of the above addresses
    nSELB <= '0' when BnPFC_int = '0' or BnPFD_int = '0' else '1';

    -- BnRW is the direction input to 74LS245A, A side to Elk, B side to 1MHz Bus
    -- 0: B->A; 1: A->B
    BnRW <= not RnW;

    -- BnRW is just a buffered version of RnW
    BRnW <= RnW;

    -- =============================================
    -- User Port
    -- =============================================

    -- nFCBx decodes address &FCBx
    nFCBx <= '0' when nPFC = '0' and A(7 downto 4) = x"B" else '1';

end Behavorial;
