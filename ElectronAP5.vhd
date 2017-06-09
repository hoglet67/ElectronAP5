----------------------------------------------------------------------------------
-- Engineer:            David Hitchens and David Banks
--
-- Create Date:         10/4/2017
-- Module Name:         Electron AP5 CPLD
-- Project Name:        Electron AP5
-- Target Devices:      XC9572
--
-- Version:             0.61
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
        Phi2:     out   std_logic;
        S1RnW:    out   std_logic;
        S2RnW:    out   std_logic;
        nSELA:    out   std_logic;
        nSELB:    out   std_logic;
        nSELT:    out   std_logic;
        nRST1:    out   std_logic;
        D:        inout std_logic_vector(7 downto 0)
    );
end ElectronAP5;

architecture Behavorial of ElectronAP5 is

constant VERSION : std_logic_vector(7 downto 0) := x"61";

-- Address that must be written to update the banksel register
constant BANKSEL_ADDR : std_logic_vector(15 downto 0) := x"AFFF";

-- Data that must be written to update the banksel register (D0 = banksel bit)
constant BANKSEL_DATA : std_logic_vector( 7 downto 0) := x"96";

-- Number of consequtive writes required: "10" would be
constant BANKSEL_COUNT : unsigned (1 downto 0)        := "10";

signal BnPFC_int : std_logic;
signal BnPFD_int : std_logic;
signal nSELA_int : std_logic;

signal syncCount : unsigned(3 downto 0);

signal AEN       : std_logic := '0';
signal BEN       : std_logic := '0';
signal CEN       : std_logic := '0';

signal test      : std_logic_vector(7 downto 0);

signal NMID      : std_logic := '0';

signal bankCount : unsigned(1 downto 0) := "00";

signal bank      : std_logic_vector(1 downto 0) := "00";

signal mode      : std_logic_vector(1 downto 0);

signal pstate    : std_logic_vector(3 downto 0) := x"0";

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
    -- Phi2 and 1MHz clock re-generation
    -- =============================================

    process(CLK16MHz)
    begin
        -- On the issue 4 Elk (once warmed up):
        --     Phi0 falls 15.6ns after 16MHz falls and 17.2ns before 16MHz rises
        --
        -- On the issue 6 Elk (once warmed up):
        --     Phi0 falls 32.4ns after 16MHz falls and 1.6ns before 16MHz rises
        --
        -- The difference is due to two additional 74LS08 gate delays on the
        -- issue 6 Elk (U18).
        --
        -- These times do drift with temperature by ~5ns (i.e. when the machine
        -- is cold, Phi0 is earlier). This is because the cooler the ULA is,
        -- the lower the propagation delays will be.
        --
        -- The XC9572 parts Dave is using are 7C speed grade, and need a
        -- setup time of 4.5ns.

        -- Conclusion: sampling Phi0 on the falling edge of 16MHz should be
        -- safe. Using the rising edge would be safe on the issue 4, but not
        -- on the issue 6.

        if falling_edge(CLK16MHz) then

            -- default action is to increment the 1MHz counter
            syncCount <= syncCount + 1;

            -- pstate tracks the phase of Phi0
            --
            -- There are three cases:
            --
            -- A normal 2MHz cycle: low for 250ns, high for 250ns (3/4 cycles)
            -- --     +--+
            --   |   /   |
            --   +--+    +--
            --
            -- A type A extended cycle: low for 250ns, high for 750ns (11/12 cycles)
            -- --+    +----------+
            --   |   /           |
            --   +--+            +--
            --
            -- A type B extended cycle: low for 250ns, high for 1250ns (19/20 cycles)
            -- --+    +------------------+
            --   |   /                   |
            --   +--+                    +--
            --
            -- The variance in number of 16MHz cycles that Phi0 appears to be
            -- high for is because the rising edge of Phi0 is very slow: 0-2V takes 44ns.
            --

            case pstate is

            -- initial state: wait for phi0 to go high
            when x"0" =>
                if Phi0 = '1' then
                    pstate <= x"1";
                end if;

            -- gitch rejection state: wait for phi0 to stay high for another cycle
            when x"1" =>
                if Phi0 = '1' then
                    pstate <= x"3";
                else
                    pstate <= x"0";
                end if;

            -- (there is no state x"2")
            -- this is so the initial states are grey coded:
            -- 0000 -> 0001 -> 0011

            -- primed state 1: act on the next falling edge of Phi0
            when x"3" =>
                if Phi0 = '1' then
                    pstate <= x"4";
                else
                    pstate <= x"8";
                    Phi2 <= '0';
                end if;

            -- primed state 2: act on the next falling edge of Phi0
            when x"4" =>
                if Phi0 = '1' then
                    pstate <= x"5";
                else
                    pstate <= x"8";
                    Phi2 <= '0';
                end if;

            -- primed state 3: act on the next falling edge of Phi0
            when x"5" =>
                if Phi0 = '1' then
                    pstate <= x"6";
                else
                    pstate <= x"8";
                    Phi2 <= '0';
                end if;

            -- primed state 4: act on the next falling edge of Phi0
            when x"6" =>
                if Phi0 = '1' then
                    pstate <= x"7";
                else
                    pstate <= x"8";
                    Phi2 <= '0';
                end if;

            -- primed state 5: act on the next falling edge of Phi0
            --
            -- at this point, phi0 has been high for 6 cycles so this MUST
            -- be a type A (12 cycles high) or type B (20 cycles high) extended cycle
            -- At the end of this cycle, we resynchronise the 1MHz clock
            when x"7" =>
                if Phi0 = '0' then
                    pstate <= x"8";
                    Phi2 <= '0';
                    syncCount <= x"0";
                end if;

            -- triggered state 0 (output phi2 held low)
            when x"8" =>
                pstate <= x"9";
            -- triggered state 1 (output phi2 held low)
            when x"9" =>
                pstate <= x"A";
            -- triggered state 2 (output phi2 held low)
            when x"A" =>
                pstate <= x"B";
            -- triggered state 3 (output phi2 held low)
            when x"B" =>
                pstate <= x"0";
                Phi2 <= '1';
            when others =>
                pstate <= x"0";
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
            if LKD02 = '1' then
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
            if LKD13 = '1' then
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
    -- ADFS mode has a 4KB RAM overlay at the and of slot 0/2
    --
    --
    -- Jumpers:                      ROM socket 0:      ROM Socket 1:
    --
    -- 11 - normal/32KB    Device:   256Kb ROM/RAM      256Kb ROM/RAM
    --                     Slot 0 A: 0000-3FFF                    (bank 0)
    --                     Slot 0 B: 4000-7FFF                    (bank 1)
    --                     Slot 1 A:                    0000-3FFF (bank 0)
    --                     Slot 1 B:                    4000-7FFF (bank 1)
    --
    -- 10 - normal/64KB    Device:   empty              256Kb ROM   512Kb ROM
    --                     Slot 0 A:                    0000-3FFF   4000-7FFF (bank 0)
    --                     Slot 0 B:                    (unmapped)  0000-3FFF (bank 1)
    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)
    --
    -- 01 - MMFS/32-64KB   Device:   128Kb RAM          256Kb ROM   512Kb ROM
    --                     Slot 0 A: 3600-3FFF          0000-35FF   4000-75FF (bank 0)
    --                     Slot 0 B: 3600-3FFF          (unmapped)  0000-35FF (bank 1)
    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)
    --
    -- 00 - ADFS/32-64KB   Device:   128Kb RAM          256Kb ROM   512Kb ROM
    --                     Slot 0 A: 3000-3FFF          0000-3FFF   4000-6FFF (bank 0)
    --                     Slot 0 B: 3000-3FFF          (unmapped)  0000-2FFF (bank 1)
    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)

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
                    -- Normal/32KB Mode
                    -- 11 - normal/32KB    Device:   256Kb ROM/RAM      256Kb ROM/RAM
                    --                     Slot 0 A: 0000-3FFF                    (bank 0)
                    --                     Slot 0 B: 4000-7FFF                    (bank 1)
                    --                     Slot 1 A:                    0000-3FFF (bank 0)
                    --                     Slot 1 B:                    4000-7FFF (bank 1)
                    if QA = '0' then
                        -- Slot 0/2
                        nCE1 <= '0';
                        if RnW = '0' and Phi0 = '1' and AEN = '1' then
                            S1RnW <= '0';
                        end if;
                        A14  <= bank(0);
                    else
                        -- Slot 1/3
                        nCE2 <= '0';
                        if RnW = '0' and Phi0 = '1' and BEN = '1' then
                            S2RnW <= '0';
                        end if;
                        A14  <= bank(1);
                    end if;

                when "10" =>
                    -- Normal/64KB Mode
                    -- 10 - normal/64KB    Device:   empty              256Kb ROM   512Kb ROM
                    --                     Slot 0 A:                    0000-3FFF   4000-7FFF (bank 0)
                    --                     Slot 0 B:                    (unmapped)  0000-3FFF (bank 1)
                    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
                    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)
                    if QA = '0' then
                        -- Slot 0/2
                        nCE2 <= '0';
                        A14   <= '0';         -- this is actually A15 into the 27512
                        S2RnW <= not bank(0); -- this is actually A14 into the 27512
                    else
                        -- Slot 1/3
                        nCE2 <= '0';
                        A14   <= '1';         -- this is actually A15 into the 27512
                        S2RnW <= not bank(1); -- this is actually A14 into the 27512
                    end if;

                when "01" =>
                    -- MMFS/32-64KB Mode
                    -- 01 - MMFS/32-64KB   Device:   128Kb RAM          256Kb ROM   512Kb ROM
                    --                     Slot 0 A: 3600-3FFF          0000-35FF   4000-75FF (bank 0)
                    --                     Slot 0 B: 3600-3FFF          (unmapped)  0000-35FF (bank 1)
                    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
                    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)
                    if QA = '0' then
                        -- Slot 0/2
                        if A(13 downto 8) >= "110110" then
                            -- Select RAM if address >= &B600
                            nCE1 <= '0';
                            -- RAM WE is not conditional on the lock flags
                            if RnW = '0' and Phi0 = '1' then
                                S1RnW <= '0';
                            end if;
                            -- A14 doesn't really matter, defaults to '1'
                        else
                            -- Otherwise, select ROM from approriate bank
                            nCE2  <= '0';
                            A14   <= '0';         -- this is actually A15 into the 27512
                            S2RnW <= not bank(0); -- this is actually A14 into the 27512
                        end if;
                    else
                        -- Slot 1/3
                        nCE2  <= '0';
                        A14   <= '1';             -- this is actually A15 into the 27512
                        S2RnW <= not bank(1);     -- this is actually A14 into the 27512
                    end if;

                when "00" =>
                    -- ADFS/32-64KB Mode
                    -- 00 - ADFS/32-64KB   Device:   128Kb RAM          256Kb ROM   512Kb ROM
                    --                     Slot 0 A: 3000-3FFF          0000-3FFF   4000-6FFF (bank 0)
                    --                     Slot 0 B: 3000-3FFF          (unmapped)  0000-2FFF (bank 1)
                    --                     Slot 1 A:                    4000-7FFF   C000-FFFF (bank 0)
                    --                     Slot 1 B:                    (unmapped)  8000-BFFF (bank 1)
                    if QA = '0' then
                        -- Slot 0/2
                        if A(13 downto 12) = "11" then
                            -- Select RAM if address >= &B000
                            nCE1 <= '0';
                            -- RAM WE is not conditional on the lock flags
                            if RnW = '0' and Phi0 = '1' then
                                S1RnW <= '0';
                            end if;
                            -- A14 doesn't really matter, defaults to '1'
                        else
                            -- Otherwise, select ROM from approriate bank
                            nCE2  <= '0';
                            A14   <= '0';         -- this is actually A15 into the 27512
                            S2RnW <= not bank(0); -- this is actually A14 into the 27512
                        end if;
                    else
                        -- Slot 1/3
                        nCE2  <= '0';
                        A14   <= '1';             -- this is actually A15 into the 27512
                        S2RnW <= not bank(1);     -- this is actually A14 into the 27512
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
            bank <= (others => '0');
        elsif falling_edge(Phi0) then
            -- detect writes
            if RnW = '0' then
                -- detect write to &AFFF
                if nROE = '0' and A(13 downto 0) = BANKSEL_ADDR(13 downto 0) and D(7 downto 1) = BANKSEL_DATA(7 downto 1) then
                    -- if this is the third write, then update the bank register
                    if bankCount = BANKSEL_COUNT then
                        -- select the slot to update based on QA
                        if QA = '0' then
                            bank(0) <= D(0);
                        else
                            bank(1) <= D(0);
                        end if;
                        -- reset bankCount
                        bankCount <= "00";
                    else
                        -- else increment bankCount
                        bankCount <= bankCount + 1;
                    end if;
                else
                    -- a write to somewhere else, so reset bankCount
                    bankCount <= "00";
                end if;
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

    -- =============================================
    -- Reset buffering
    -- =============================================

    nRST1 <= '0' when nRST = '0' else 'Z';
    
end Behavorial;
