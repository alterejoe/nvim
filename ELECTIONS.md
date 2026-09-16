-- csvgen quick reference — press <leader>sk to show all keybinds

-- <leader>sc  (visual)  Contest choices
-- Input:  1(3) 2(2)
-- Output: #ExternalChoiceId,ExternalContestId,Name,ShortName,IsDisabled,SequenceNumber,SecondName
--         1,1,"",,False,1,
--         2,1,"",,False,2,
--         3,1,"",,False,3,
--         4,2,"",,False,1,
--         5,2,"",,False,2,

-- <leader>sg  (visual)  Contest template (scaffold)
-- Input:  1-5
-- Output: 1()
--         2()
--         3()
--         4()
--         5()

-- <leader>sn  (visual)  ShortName from Name (col 3→4)
-- Input:  1,2,"Precinct 1 - Central",OldName,...
-- Output: 1,2,"Precinct 1 - Central","PRECINCT  CENTRAL",...

-- <leader>sm  (visual)  Contest → Precinct Split (BallotPosition=None)
-- Input:  1(10-12) 2(13-14)
-- Output: #ContestExternalId,PrecinctSplitExternalId,BallotPosition
--         1,10,None
--         1,11,None
--         1,12,None
--         2,13,None
--         2,14,None

-- <leader>sd  (visual)  Contest → District
-- Input:  1(1) 2(2-3)
-- Output: #ContestExternalId,DistrictExternalId
--         1,1
--         2,2
--         2,3

-- <leader>sx  (visual)  District → Precinct Split
-- Input:  1(10-12)
-- Output: #DistrictExternalId,PrecinctSplitExternalId
--         1,10
--         1,11
--         1,12

-- <leader>sa  (visual)  Poll Place → Precinct Split
-- Input:  1(10-12) 2(13)
-- Output: #PollPlaceExternalId,PrecinctSplitExternalId
--         1,10
--         1,11
--         1,12
--         2,13

-- <leader>sp  (n+v)  Precinct CSV from pattern
-- Input:  A1-3(REP,DEM) 5(BALLOT) !CityHall(OFFICE,BEDECK)
-- Output: #Id,PrecinctName,Name,SequenceNumber
--         1,"A1","REP",1
--         2,"A1","DEM",2
--         3,"A2","REP",3
--         ...

-- <leader>sb  (n+v)  Ballot → Precinct Split CSV
-- Input:  1(10-12) 2(13)
-- Output: #BallotTextExternalId,PrecinctSplitExternalId
--         1,10
--         1,11
--         1,12
--         2,13

-- <leader>sv  (n+v)  Ballot → District CSV
-- Input:  1(1-2) 3(1)
-- Output: #BallotTextExternalId,DistrictExternalId
--         1,1
--         1,2
--         3,1

-- <leader>se  (normal)  Excel paste → CSV (whole buffer)
-- <leader>ec (visual)   Excel paste → CSV (selection only)
-- Both replace tabs with commas in-place.
