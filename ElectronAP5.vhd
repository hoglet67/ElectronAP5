----------------------------------------------------------------------------------
-- Engineer:            David Hitchens and David Banks
--
-- Create Date:         10/4/2017
-- Module Name:         Electron AP5 CPLD
-- Project Name:        Electron AP5
-- Target Devices:      XC9572
--
-- Version:             0.5C
--
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
        nNMI:     out   std_logic;
        nOE13:    out   std_logic;
        nOE1:     out   std_logic;
        nOE2:     out   std_logic;
        S1RnW:    out   std_logic;
        S2RnW:    out   std_logic;
        nSELA:    out   std_logic;
        nSELB:    out   std_logic;
        nSELT:    out   std_logic;
        D:        inout std_logic_vector(7 downto 0)
    );
end ElectronAP5;

architecture Behavorial of ElectronAP5 is

constant VERSION : std_logic_vector(7 downto 0) := x"5C";

signal BnPFC_int : std_logic;
signal BnPFD_int : std_logic;
signal nSELA_int : std_logic;

signal Phi0S     : std_logic;
signal state     : std_logic_vector(1 downto 0);
signal syncCount : unsigned(3 downto 0);

signal AEN       : std_logic := '0';
signal BEN       : std_logic := '0';
signal CEN       : std_logic := '0';

signal test      : std_logic_vector(7 downto 0);

signal NMID      : std_logic := '0';

signal bank      : std_logic_vector(1 downto 0) := "00";

signal mode      : std_logic_vector(1 downto 0);

begin

    -- =============================================
    -- Test Register
    -- =============================================

    -- Initialized on reset to 0x51 (the version number)
    -- Read/Write at &FCD7

    process(Phi0, nRST)
    begin
        if nRST = '0' then
            test <= VERSION;
        elsif falling_edge(Phi0) then
            if nPFC = '0' and RnW = '0' and A(7 downto 0) = x"D7" then
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

    process(CLK16MHz)
    begin
        -- Synchronise Phi0 going in to the state machine
        if falling_edge(CLK16MHz) then
            Phi0S <= Phi0;
        end if;
        if rising_edge(CLK16MHz) then
            -- default action is to increment the counter
            syncCount <= syncCount + 1;
            -- state machine has four gray-coded states
            case state is
            -- idle state: wait for nRST to go low
            when "00" =>
                if nRST = '0' then
                    state <= "01";
                end if;
            -- reset state: wait for nRST to go high
            when "01" =>
                if nRST = '1' then
                    state <= "11";
                end if;
            -- primed state: wait for a read of the tube to start
            when "11" =>
                if nRST = '0' then
                    state <= "01";
                elsif nSELA_int = '0' and RnW = '1' and Phi0S = '1' then
                    state <= "10";
                end if;
            -- loading state: wait for Phi to go low, and then load the counter
            when "10" =>
                if Phi0S = '0' then
                    syncCount <= x"1";
                    state <= "00";
                end if;
            when others =>
                state <= "00";
            end case;
        end if;
    end process;

    B1MHz <= syncCount(3);

    -- =============================================
    -- NMI
    -- =============================================
    --
    -- Synchronize NMI from the 1MHz bus with Phi0

    process(Phi0, nRST)
    begin
        if (nRST = '0') then
            NMID <= '0';
        elsif falling_edge(Phi0) then
            NMID <= not nNMI1MHz;
        end if;
    end process;

    -- nNMI needs to be an open collector output
    nNMI <= '0' when NMID = '1' else 'Z';

    -- =============================================
    -- ROMs
    -- =============================================

    -- Software Write Enables for the two ROMs:
    --   AEN enables write to ROM 0/2
    --   BEN enables write to ROM 1/3
    --   CEN enables write to ROM 13
    --
    -- During reset, to reduce the possibility of write glitches
    --   AEN is locked
    --   BEN is locked
    --   CEN is locked
    --
    -- After reset:
    --   If LKD02 is present (0), AEN is unlocked
    --   If LKD03 is present (1), BEN is unlocked
    --
    -- Write to &FCDA - Unlock ROM 13
    -- Write to &FCDB - Lock ROM 13
    -- Write to &FCDC - Unlock ROM 0/2
    -- Write to &FCDD - Lock ROM 0/2
    -- Write to &FCDE - Unlock ROM 1/3
    -- Write to &FCDF - Lock ROM 1/3

    process(Phi0, nRST)
    begin
        if nRST = '0' then
            -- default to locked during/on reset
            AEN <= '0';
            BEN <= '0';
            CEN <= '0';
        elsif falling_edge(Phi0) then
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
            -- no lock disable jumper for rom 13
            if A(7 downto 0) = x"DA" and nPFC = '0' and RnW = '0' then
                CEN <= '1';
            end if;
            if A(7 downto 0) = x"DB" and nPFC = '0' and RnW = '0' then
                CEN <= '0';
            end if;
        end if;
    end process;

    -- BnRW13 drives nWE of ROM13, and is a gated version of RnW
    BRnW13 <= '0' when RnW = '0' and CEN = '1' and Phi0 = '1' else '1';

    -- nCE13 drives nCE of ROM13
    nCE13 <= nROM13;

    -- nOE13 drives nOE of ROM13, disable during writes
    nOE13 <= not RnW;

    -- Summary of the different ROM modes
    --
    -- Note: addresses refer to the address within the device
    --
    -- MMFS mode has a 2.5KB RAM overlay at the end of slot 0/2
    -- ADFS mode has a 4KB RAM overlay at the and of slot 1/3
    --
    --
    -- Jumpers:                      ROM socket 0:      ROM Socket 1:
    --
    -- 11 - normal/16KB    Device:   128Kb ROM/RAM      128Kb ROM/RAM
    --                     Slot 0:   0000-3FFF
    --                     Slot 1:                      0000-3FFF
    --
    -- 10 - normal/32KB    Device:   empty              256Kb ROM/RAM
    --                     Slot 0:                      0000-3FFF
    --                     Slot 1:                      4000-7FFF
    --
    -- 01 - MMFS/32KB      Device:   128Kb RAM          256Kb ROM
    --                     Slot 0:                      0000-3FFF
    --                     Slot 1:   3600-3FFF          4000-75FF
    --
    -- 00 - ADFS/64KB      Device:   128Kb RAM          512Kb ROM
    --                     Slot 0:                      C000-FFFF
    --                     Slot 1 A: 3000-3FFF          0000-2FFF (bank 0)
    --                     Slot 1 B: 3000-3FFF          4000-6FFF (bank 1)
    --                     Slot 1 C: 3000-3FFF          8000-AFFF (bank 2)
    --

    -- For mode from the two existing jumpers
    mode <= MMCM & R13256KS;
    
    process(mode, QA, RnW, AEN, BEN, Phi0, nROE, A, bank)
    begin

        -- Default values for all outputs, so we don't accidentally infer a latch
        S1RnW <= '1';
        nCE1  <= '1';
        S2RnW <= '1';
        nCE2  <= '1';
        A14   <= '1'; -- this defaults to '1' as it is nPGM on a 27128

        -- Everything is conditional on nROE being active
        if nROE = '0' then

            -- To make this manageable and easily extensible, we use a big case
            -- statement with case per mode, controlling which device gets selected
            -- and whether RnW is enabled. Each case then starts by looking at
            -- QA. Although not the most compact way to represent the logic, is
            -- is probably the most readable.

            case mode is
                when "11" =>
                    -- Normal/16KB Mode
                    if QA = '0' then
                        -- Slot 0/2
                        nCE1 <= '0';
                        if RnW = '0' and Phi0 = '1' and AEN = '1' then
                            S1RnW <= '0';
                        end if;
                    else
                        -- Slot 1/3
                        nCE2 <= '0';
                        if RnW = '0' and Phi0 = '1' and BEN = '1' then
                            S2RnW <= '0';
                        end if;
                    end if;

                when "10" =>
                    -- Normal/32KB Mode
                    if QA = '0' then
                        -- Slot 0/2
                        nCE2 <= '0';
                        A14  <= '0';
                        if RnW = '0' and Phi0 = '1' and AEN = '1' then
                            S2RnW <= '0';
                        end if;
                    else
                        -- Slot 1/3
                        nCE2 <= '0';
                        A14  <= '1';
                        if RnW = '0' and Phi0 = '1' and BEN = '1' then
                            S2RnW <= '0';
                        end if;
                    end if;

                when "01" =>
                    -- MMFS Mode
                    if QA = '0' then
                        -- Slot 0/2
                        nCE2 <= '0';
                        A14  <= '0';
                        if RnW = '0' and Phi0 = '1' and AEN = '1' then
                            S2RnW <= '0';
                        end if;
                    else
                        -- Slot 1/3
                        if A(13 downto 8) >= "110110" then
                            -- Select RAM if address >= &B600
                            nCE1 <= '0';
                            -- RAM WE is not conditional on the lock flags
                            if RnW = '0' and Phi0 = '1' then
                                S1RnW <= '0';
                            end if;
                        else
                            -- Otherwise, select ROM
                            nCE2 <= '0';
                            A14  <= '1';
                            if RnW = '0' and Phi0 = '1' and BEN = '1' then
                                S2RnW <= '0';
                            end if;
                        end if;
                    end if;

                when "00" =>
                    -- ADFS Mode
                    if QA = '0' then
                        -- Slot 0/2
                        nCE2  <= '0';
                        A14   <= '1'; -- this is actually A15 into the 27512
                        S2RnW <= '1'; -- this is actually A14 into the 27512
                    else
                        -- Slot 1/3
                        if A(13 downto 12) = "11" then
                            -- Select RAM if address >= &B000
                            nCE1 <= '0';
                            -- RAM WE is not conditional on the lock flags
                            if RnW = '0' and Phi0 = '1' then
                                S1RnW <= '0';
                            end if;
                        else
                            -- Otherwise, select ROM from approriate bank
                            nCE2  <= '0';
                            A14   <= bank(1); -- this is actually A15 into the 27512
                            S2RnW <= bank(0); -- this is actually A14 into the 27512
                        end if;
                    end if;

                when others =>
                    -- for undefined modes, use defaults set before case
            end case;
        end if;
    end process;

    -- nOE1 drives nOE of ROM 0/2, always disable during writes
    nOE1 <= not RnW;

    -- nOE2 drives nOE of ROM 1/3, always disable during writes
    nOE2 <= not RnW;

    -- Bank select registers
    process(Phi0, nRST)
    begin
        if nRST = '0' then
            -- default to bank 0 on reset
            bank <= "00";
        elsif falling_edge(Phi0) then
            -- detect write to &AFFF but only when slot 1/3 paged in
            if nROE = '0' and RnW = '0' and QA = '1' and A(13 downto 12) = "10" and A(11 downto 0) = x"FFF" then
                bank <= D(1 downto 0);
            end if;
        end if;
    end process;

    -- =============================================
    -- Tube
    -- =============================================

    -- nSELT decodes address &FCEx and becomes nTUBE (pin 8) on the tube connector
    nSELT <= '0' when nPFC = '0' and A(7 downto 4) = x"E" else '1';

    -- nSELA decodes address &FCEx and enables the 74LS245
    -- Gating with Phi0 reduces the possibility of any bus contention
    nSELA_int <= '0' when nPFC = '0' and A(7 downto 4) = x"E" and Phi0 = '1' else '1';
    nSELA <= nSELA_int;

    -- DIRA is direction input to 74LS245A, A side to Tube, B side to Elk
    -- 0: B->A; 1: A->B
    DIRA  <= RnW;

    -- =============================================
    -- 1MHZ Bus
    -- =============================================

    -- BnPFC decodes addresses:
    --   &FC0x, &FC1x, &FC2x, &FC3x, &FC4x, &FC8x, &FCAx, &FCFx
    BnPFC_int <= '0' when nPFC = '0' and (
        A(7 downto 4) = x"0" or
        A(7 downto 4) = x"1" or
        A(7 downto 4) = x"2" or
        A(7 downto 4) = x"3" or
        A(7 downto 4) = x"4" or
        A(7 downto 4) = x"8" or
        A(7 downto 4) = x"A" or
        A(7 downto 4) = x"F") else '1';
    BnPFC <= BnPFC_int;

    -- BnPFD decodes addresses &FDxx
    BnPFD_int <= nPFD;
    BnPFD <= BnPFD_int;

    -- nSELB is the enable input to LS245A, asserted for any of the above addresses
    nSELB <= '0' when (BnPFC_int = '0' or BnPFD_int = '0') and Phi0 = '1' else '1';

    -- BnRW is the direction input to 74LS245A, A side to Elk, B side to 1MHz Bus
    -- 0: B->A; 1: A->B
    BnRW <= not RnW;

    -- BRnW is just a buffered version of RnW
    BRnW <= RnW;

    -- =============================================
    -- User Port
    -- =============================================

    -- nFCBx decodes address &FCBx
    nFCBx <= '0' when nPFC = '0' and A(7 downto 4) = x"B" else '1';

end Behavorial;
