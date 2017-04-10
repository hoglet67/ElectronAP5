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

-- TODO:
--    add an output which drives pin 27 (RnW) of the ROMs
--    discuss if nLoadDash needs an async reset

entity ElectronAP5 is
    Port (
        A:        in  std_logic_vector(7 downto 4);
        CLK16MHz: in  std_logic;
        nNMI1MHz: in  std_logic;
        nPFC:     in  std_logic;
        nPFD:     in  std_logic;
        nROE:     in  std_logic;
        nROM13:   in  std_logic;
        nRST:     in  std_logic;
        Phi0:     in  std_logic;
        QA:       in  std_logic;
        R13256KS: in  std_logic;
        R13D:     in  std_logic;
        RnW:      in  std_logic;
        A14:      out std_logic;
        B1MHz:    out std_logic;
        BnPFC:    out std_logic;
        BnPFD:    out std_logic;
        BnRW:     out std_logic;
        BRnW:     out std_logic;
        DIRA:     out std_logic;
        nCE13:    out std_logic;
        nCE1:     out std_logic;
        nCE2:     out std_logic;
        nFCBx:    out std_logic;
        NMID:     out std_logic;
        nOE1:     out std_logic;
        nOE2:     out std_logic;
        nSELA:    out std_logic;
        nSELB:    out std_logic
    );
end ElectronAP5;

architecture Behavorial of ElectronAP5 is

signal BnPFC_int : std_logic;
signal BnPFD_int : std_logic;
signal nSELA_int : std_logic;

signal seenRst   : std_logic;
signal nLoadIn   : std_logic;
signal nLoad     : std_logic;
signal nLoadDash : std_logic;
signal syncCount : unsigned(3 downto 0);

begin

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
        if rising_edge(CLK16MHZ) then            
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
        elsif rising_edge(Phi0) then
            NMID <= nNMI1MHz;
        end if;
    end process;

    -- =============================================
    -- ROMs
    -- =============================================

    -- nCE13, jumper on R13D disables this ROM
    nCE13 <= nROM13 when R13D = '1' else '1';

    -- nOE1 drives ROM 0/2
    nOE1 <= '0' when RnW = '1' else '1';

    -- nCE1 drives ROM 0/2 - disable (and use nCE2) when 256K jumper is present
    nCE1 <= '0' when nROE = '0' and (QA = '0' and R13256KS = '0') else '1';

    -- nOE2 drives ROM 1/3
    nOE2 <= '0' when RnW = '1' else '1';

    -- nCE2 drives ROM 1/3 - enable (instead of nCE1) when 256K jumper is present
    nCE2 <= '0' when nROE = '0' and (QA = '1' or R13256KS = '1') else '1';

    -- A14 drives ROM 1/3 from QA when the 256K jumper is present
    A14 <= QA when R13256KS = '1' else '1';

    -- =============================================
    -- Tube
    -- =============================================

    -- nSELA decodes address &FCEx
    nSELA_int <= '0' when nPFC = '0' and A(7 downto 4) = x"E" else '1';
    nSELA <= nSELA_int;
    
    -- DIRA is direction input to 74LS245A, A side to Elk, B side to Tube)
    -- 0: B->A; 1: A->B
    DIRA  <= '0' when nSELA_int = '0' and RnW = '1' else '1';

    -- =============================================
    -- 1MHZ Bus
    -- =============================================

    -- BnPFC decodes addresses &FC8x, &FCAx, &FCFx
    BnPFC_int <= '0' when nPFC = '0' and (A(7 downto 4) = x"8" or A(7 downto 4) = x"A" or A(7 downto 4) = x"F") else '1';
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

