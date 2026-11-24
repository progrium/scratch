      *> payroll.cob: weekly payroll for a small firm, in COBOL.
      *>
      *>   uitree-headless -d ALPINE:#L cobc -x payroll.cob
      *>   uitree -t Payroll -d ALPINE:#L ./payroll
      *>
      *> GnuCOBOL builds a Linux program, so it runs in the h9 machine
      *> on an Alpine root (ALPINE is a tree with gnucobol installed),
      *> where the tree is at $ui, as for a Plan 9 client. COBOL does
      *> all the file work itself, through ordinary SELECT ... ASSIGN
      *> files whose names are set at run time: it sets up the main
      *> window, writes the screen as a tree document, reads the events
      *> file one record (one event) at a time, and reads each input's
      *> value file. An event record starts name key path, so one
      *> UNSTRING ... DELIMITED BY SPACE finds what to do. Each run is
      *> then one ctl write: field errors, the pay stub, the register,
      *> the total and the cleared inputs, as set lines with here-values
      *> for the multi-line ones. CLOSE applies them all in one frame.
      *>
      *> Money is fixed-point decimal, as COBOL has always done it:
      *> PIC 9(7)V99 fields, COMPUTE ROUNDED, and edited pictures like
      *> $$$,$$$,$$9.99 for display. Time over 40 hours is paid at
      *> time and a half. The tax table is made up.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. PAYROLL.

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT EVENTS ASSIGN TO EVENTS-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS EVENTS-STATUS.
           SELECT GUI ASSIGN TO GUI-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS GUI-STATUS.
           SELECT GUI-IN ASSIGN TO GUI-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS GUI-IN-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  EVENTS.
       01  EVENT-REC               PIC X(1024).
       FD  GUI.
       01  GUI-REC                 PIC X(1024).
       FD  GUI-IN.
       01  GUI-IN-REC              PIC X(1024).

       WORKING-STORAGE SECTION.
       01  BASE                    PIC X(200).
       01  REL                     PIC X(200).
       01  EVENTS-PATH             PIC X(256).
       01  GUI-PATH                PIC X(256).
       01  EVENTS-STATUS           PIC XX.
       01  GUI-STATUS              PIC XX.
       01  GUI-IN-STATUS           PIC XX.
       01  LN                      PIC X(1024).
       01  EV                      PIC X(1024).
       01  EV-NAME                 PIC X(32).
       01  EV-KEY                  PIC X(64).
       01  EV-PATH                 PIC X(200).
       01  DONE-FLAG               PIC X VALUE "N".
           88  DONE                VALUE "Y".
       01  VAL                     PIC X(200).
       01  HOURS-IN                PIC X(200).
       01  RATE-IN                 PIC X(200).
       01  FLD                     PIC X(40).
       01  ERR                     PIC X(80).

      *> One run: what was typed, and what it comes to.
       01  EMP-NAME                PIC X(40).
       01  HOURS                   PIC 9(3)V99.
       01  RATE                    PIC 9(4)V99.
       01  REG-HRS                 PIC 9(3)V99.
       01  OT-HRS                  PIC 9(3)V99.
       01  REG-PAY                 PIC 9(7)V99.
       01  OT-PAY                  PIC 9(7)V99.
       01  GROSS                   PIC 9(7)V99.
       01  FED                     PIC 9(7)V99.
       01  FICA                    PIC 9(7)V99.
       01  NET                     PIC 9(7)V99.
       01  OK-FLAG                 PIC X.
           88  ALL-OK              VALUE "Y".

      *> The register: every stub run this session, as display text.
       01  REG-COUNT               PIC 99 VALUE 0.
       01  REGISTER.
           05  REG-LINE OCCURS 99 TIMES.
               10  R-NAME          PIC X(40).
               10  R-HOURS         PIC X(10).
               10  R-RATE          PIC X(12).
               10  R-GROSS         PIC X(16).
               10  R-TAX           PIC X(16).
               10  R-NET           PIC X(16).
       01  I                       PIC 99.
       01  TOTAL-GROSS             PIC 9(9)V99 VALUE 0.
       01  TOTAL-NET               PIC 9(9)V99 VALUE 0.

      *> Edited pictures: COBOL's number formatting.
       01  MONEY                   PIC $$$,$$$,$$9.99.
       01  BIG-MONEY               PIC $$$,$$$,$$$,$$9.99.
       01  HRS-ED                  PIC ZZ9.99.
       01  N-ED                    PIC Z9.

       PROCEDURE DIVISION.
       MAIN.
           ACCEPT BASE FROM ENVIRONMENT "ui"
           IF BASE = SPACES
               MOVE "/mnt/ui" TO BASE
           END-IF
           PERFORM BUILD-SCREEN
           MOVE SPACES TO EVENTS-PATH
           STRING FUNCTION TRIM(BASE) "/events" DELIMITED BY SIZE
               INTO EVENTS-PATH
           OPEN INPUT EVENTS
           PERFORM UNTIL DONE
               READ EVENTS INTO EV
                   AT END SET DONE TO TRUE
                   NOT AT END PERFORM HANDLE-EVENT
               END-READ
           END-PERFORM
           CLOSE EVENTS
           STOP RUN.

      *> The button, Enter in an input (the form's tag is inherited)
      *> and cmd-enter all have the key "run". Closing the window
      *> quits the app, which ends the events file.
       HANDLE-EVENT.
           MOVE SPACES TO EV-NAME EV-KEY EV-PATH
           UNSTRING EV DELIMITED BY SPACE
               INTO EV-NAME EV-KEY EV-PATH
           IF EV-KEY = "run" AND (EV-NAME = "click"
                   OR EV-NAME = "submit" OR EV-NAME = "action")
               PERFORM RUN-PAYROLL
           END-IF.

      *> ---- The screen -------------------------------------------
       BUILD-SCREEN.
           MOVE "/win/main/ctl" TO REL
           PERFORM OPEN-GUI
           MOVE "set . title=Payroll size=820,600 min=640,480"
               TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/keys" TO REL
           PERFORM OPEN-GUI
           MOVE "cmd-enter run" TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/win/main/tree" TO REL
           PERFORM OPEN-GUI
           MOVE "div root  : v-flex size-full p=20 gap=14 bg=background"
               TO LN
           PERFORM SAY
           MOVE "  div head  : h-flex items-baseline gap=10" TO LN
           PERFORM SAY
           STRING "    text h  text='ACME Widget Co.'  "
               ": text-xl font-semibold"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           STRING "    text sub  "
               "text='Weekly payroll, computed in COBOL'  "
               ": text-sm text-color=muted-foreground"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE "  form f  labels=side  tag=run" TO LN
           PERFORM SAY
           MOVE "    field name  label=Employee" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder='Grace Hopper'" TO LN
           PERFORM SAY
           MOVE "    field hours  label=Hours" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder=40" TO LN
           PERFORM SAY
           MOVE "    field rate  label='Rate per hour'" TO LN
           PERFORM SAY
           MOVE "      input in  placeholder=25.00" TO LN
           PERFORM SAY
           MOVE "    field go  label=' '" TO LN
           PERFORM SAY
           MOVE "      button run  label='Run payroll'  primary"
               TO LN
           PERFORM SAY
           MOVE "  div body  : h-flex flex-1 gap=14 items-stretch"
               TO LN
           PERFORM SAY
           MOVE "    div left  : v-flex gap=8 w=300" TO LN
           PERFORM SAY
           MOVE "      text t1  text='Pay stub'  : font-semibold"
               TO LN
           PERFORM SAY
           MOVE "      description-list stub  bordered  columns=1"
               TO LN
           PERFORM SAY
           MOVE "    div right  : v-flex flex-1 gap=8" TO LN
           PERFORM SAY
           MOVE "      text t2  text=Register  : font-semibold"
               TO LN
           PERFORM SAY
           MOVE "      table reg  stripe  : flex-1" TO LN
           PERFORM SAY
           STRING "      text total  text='No one paid yet.'  "
               ": text-sm text-right text-color=muted-foreground"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           CLOSE GUI

      *>   Data files are lines of words, quoted where they hold blanks.
           MOVE "/win/main/body/right/reg/columns" TO REL
           PERFORM OPEN-GUI
           MOVE "emp Employee 170" TO LN
           PERFORM SAY
           MOVE "hrs Hours 70 align=right" TO LN
           PERFORM SAY
           MOVE "rate Rate 80 align=right" TO LN
           PERFORM SAY
           MOVE "net 'Net pay' 110 align=right" TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/win/main/body/left/stub/items" TO REL
           PERFORM OPEN-GUI
           MOVE "Employee -" TO LN
           PERFORM SAY
           CLOSE GUI
           MOVE "/win/main/focus" TO REL
           PERFORM OPEN-GUI
           MOVE "f/name/in" TO LN
           PERFORM SAY
           CLOSE GUI.

      *> ---- One run ----------------------------------------------
      *> Read the three inputs, then write one ctl: every line in it
      *> applies together when it is closed.
       RUN-PAYROLL.
           SET ALL-OK TO TRUE
           MOVE "/win/main/f/name/in/value" TO REL
           PERFORM READ-VALUE
           MOVE VAL TO EMP-NAME
           MOVE "/win/main/f/hours/in/value" TO REL
           PERFORM READ-VALUE
           MOVE VAL TO HOURS-IN
           MOVE "/win/main/f/rate/in/value" TO REL
           PERFORM READ-VALUE
           MOVE VAL TO RATE-IN

           MOVE "/win/main/ctl" TO REL
           PERFORM OPEN-GUI

           MOVE SPACES TO ERR
           IF EMP-NAME = SPACES
               MOVE "Who are we paying?" TO ERR
           END-IF
           MOVE "f/name" TO FLD
           PERFORM SET-ERROR

           MOVE SPACES TO ERR
           IF FUNCTION TEST-NUMVAL(HOURS-IN) NOT = 0
                   OR HOURS-IN = SPACES
               MOVE "Hours must be a number" TO ERR
           ELSE
               IF FUNCTION NUMVAL(HOURS-IN) > 168
                       OR FUNCTION NUMVAL(HOURS-IN) <= 0
                   MOVE "There are 168 hours in a week" TO ERR
               ELSE
                   COMPUTE HOURS ROUNDED = FUNCTION NUMVAL(HOURS-IN)
               END-IF
           END-IF
           MOVE "f/hours" TO FLD
           PERFORM SET-ERROR

           MOVE SPACES TO ERR
           IF FUNCTION TEST-NUMVAL-C(RATE-IN) NOT = 0
                   OR RATE-IN = SPACES
               MOVE "Rate must be an amount" TO ERR
           ELSE
               IF FUNCTION NUMVAL-C(RATE-IN) > 9999.99
                       OR FUNCTION NUMVAL-C(RATE-IN) <= 0
                   MOVE "Rate must be 0.01 to 9,999.99" TO ERR
               ELSE
                   COMPUTE RATE ROUNDED = FUNCTION NUMVAL-C(RATE-IN)
               END-IF
           END-IF
           MOVE "f/rate" TO FLD
           PERFORM SET-ERROR

           IF ALL-OK
               PERFORM COMPUTE-PAY
               PERFORM SHOW-STUB
               PERFORM ADD-TO-REGISTER
               PERFORM CLEAR-INPUTS
           END-IF
           CLOSE GUI.

      *> SET-ERROR: a set line for FLD's error; spaces clear it.
       SET-ERROR.
           IF ERR = SPACES
               STRING "set " FUNCTION TRIM(FLD) " error="
                   DELIMITED BY SIZE INTO LN
           ELSE
               MOVE "N" TO OK-FLAG
               STRING "set " FUNCTION TRIM(FLD) " error='"
                   FUNCTION TRIM(ERR) "'"
                   DELIMITED BY SIZE INTO LN
           END-IF
           PERFORM SAY.

       COMPUTE-PAY.
           IF HOURS > 40
               MOVE 40 TO REG-HRS
               COMPUTE OT-HRS = HOURS - 40
           ELSE
               MOVE HOURS TO REG-HRS
               MOVE 0 TO OT-HRS
           END-IF
           COMPUTE REG-PAY ROUNDED = REG-HRS * RATE
           COMPUTE OT-PAY ROUNDED = OT-HRS * RATE * 1.5
           COMPUTE GROSS = REG-PAY + OT-PAY
      *>   10% of the first $500 a week, 22% of the rest.
           IF GROSS > 500
               COMPUTE FED ROUNDED = 50 + (GROSS - 500) * 0.22
           ELSE
               COMPUTE FED ROUNDED = GROSS * 0.10
           END-IF
           COMPUTE FICA ROUNDED = GROSS * 0.0765
           COMPUTE NET = GROSS - FED - FICA.

      *> The stub's items, as a here-value: label, then amount.
       SHOW-STUB.
           MOVE "set body/left/stub items=<<END" TO LN
           PERFORM SAY
           STRING "Employee '" FUNCTION TRIM(EMP-NAME) "'"
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE REG-HRS TO HRS-ED
           MOVE REG-PAY TO MONEY
           STRING "'Regular, " FUNCTION TRIM(HRS-ED) " h' "
               FUNCTION TRIM(MONEY) DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE OT-HRS TO HRS-ED
           MOVE OT-PAY TO MONEY
           STRING "'Overtime, " FUNCTION TRIM(HRS-ED) " h at 1.5' "
               FUNCTION TRIM(MONEY) DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE GROSS TO MONEY
           STRING "'Gross pay' " FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE FED TO MONEY
           STRING "'Federal tax' -" FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE FICA TO MONEY
           STRING "'FICA, 7.65%' -" FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE NET TO MONEY
           STRING "'Net pay' " FUNCTION TRIM(MONEY)
               DELIMITED BY SIZE INTO LN
           PERFORM SAY
           MOVE "END" TO LN
           PERFORM SAY.

       ADD-TO-REGISTER.
           IF REG-COUNT < 99
               ADD 1 TO REG-COUNT
           END-IF
           MOVE EMP-NAME TO R-NAME(REG-COUNT)
           MOVE HOURS TO HRS-ED
           MOVE FUNCTION TRIM(HRS-ED) TO R-HOURS(REG-COUNT)
           MOVE RATE TO MONEY
           MOVE FUNCTION TRIM(MONEY) TO R-RATE(REG-COUNT)
           MOVE NET TO MONEY
           MOVE FUNCTION TRIM(MONEY) TO R-NET(REG-COUNT)
           ADD GROSS TO TOTAL-GROSS
           ADD NET TO TOTAL-NET

           MOVE "set body/right/reg rows=<<END" TO LN
           PERFORM SAY
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > REG-COUNT
               MOVE I TO N-ED
               STRING "r" FUNCTION TRIM(N-ED) " '"
                   FUNCTION TRIM(R-NAME(I)) "' "
                   FUNCTION TRIM(R-HOURS(I)) " "
                   FUNCTION TRIM(R-RATE(I)) " "
                   FUNCTION TRIM(R-NET(I))
                   DELIMITED BY SIZE INTO LN
               PERFORM SAY
           END-PERFORM
           MOVE "END" TO LN
           PERFORM SAY

           MOVE REG-COUNT TO N-ED
           MOVE TOTAL-GROSS TO BIG-MONEY
           MOVE SPACES TO VAL
           STRING "set body/right/total text='"
               FUNCTION TRIM(N-ED) " paid. Gross "
               FUNCTION TRIM(BIG-MONEY) DELIMITED BY SIZE INTO VAL
           MOVE TOTAL-NET TO BIG-MONEY
           STRING FUNCTION TRIM(VAL) ", net "
               FUNCTION TRIM(BIG-MONEY) ".'" DELIMITED BY SIZE INTO LN
           PERFORM SAY.

       CLEAR-INPUTS.
           MOVE "set f/name/in value=" TO LN
           PERFORM SAY
           MOVE "set f/hours/in value=" TO LN
           PERFORM SAY
           MOVE "set f/rate/in value=" TO LN
           PERFORM SAY
           MOVE "set . focus=f/name/in" TO LN
           PERFORM SAY.

      *> ---- File helpers ------------------------------------------
      *> OPEN-GUI: open BASE followed by REL for output.
       OPEN-GUI.
           MOVE SPACES TO GUI-PATH
           STRING FUNCTION TRIM(BASE) FUNCTION TRIM(REL)
               DELIMITED BY SIZE INTO GUI-PATH
           OPEN OUTPUT GUI
           MOVE SPACES TO LN.

      *> SAY: write LN as one line of the open file.
       SAY.
           WRITE GUI-REC FROM LN
           MOVE SPACES TO LN.

      *> READ-VALUE: the first line of BASE followed by REL, into VAL.
       READ-VALUE.
           MOVE SPACES TO GUI-PATH VAL
           STRING FUNCTION TRIM(BASE) FUNCTION TRIM(REL)
               DELIMITED BY SIZE INTO GUI-PATH
           OPEN INPUT GUI-IN
           IF GUI-IN-STATUS = "00"
               READ GUI-IN INTO VAL
                   AT END CONTINUE
               END-READ
               CLOSE GUI-IN
           END-IF.
