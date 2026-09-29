import ../examples/gods_of_the_arena/scores

echo "Testing Emmett's Glory uses whole XP per elapsed minute"
doAssert score(3000, 14400, true) == 300
doAssert score(3000, 15120, true) == 285
doAssert score(1000, 720, true) == 2000
doAssert score(1000, 721, true) == 1997
doAssert score(1000, 1441, true) == 999
doAssert score(4001, 28800, true) == 200

echo "Testing losses, zero duration, and zero XP"
doAssert score(3000, 14400, false) == 0
doAssert score(1000, 0, true) == 0
doAssert score(1000, -1, true) == 0
doAssert score(0, 1440, true) == 0
doAssert score(-1, 1440, true) == 0

echo "Testing seat order and wide score intermediates"
doAssert score(2_147_483_647, 1440, true) == 2_147_483_647
doAssert score(2_147_483_647, 28800, true) == 107_374_182
doAssert scores(@[3000, 5000, 2000], 14400, @[1, 0, 1]) == @[300, 0, 200]
doAssert scores(@[3000, 5000, 2000], 14400, @[0, 0, 0]) == @[0, 0, 0]
