SHEETS_S = (1..50).map { |n| { 'id' => n, 'rank' => 'S', 'num' => n, 'price' => 5000 } }
SHEETS_A = (51..200).map { |n| { 'id' => n, 'rank' => 'A', 'num' => n - 50, 'price' => 3000 } }
SHEETS_B = (201..500).map { |n| { 'id' => n, 'rank' => 'B', 'num' => n - 200, 'price' => 1000 } }
SHEETS_C = (501..1000).map { |n| { 'id' => n, 'rank' => 'C', 'num' => n - 500, 'price' => 0 } }
SHEETS = SHEETS_S + SHEETS_A + SHEETS_B + SHEETS_C
