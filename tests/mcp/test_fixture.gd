extends GutTest

func test_success():
	assert_eq(2 + 2, 4)
	gut.p("MCP fixture output")
	gut.logger.warn("MCP fixture warning")

func test_failure():
	assert_eq(2 + 2, 5, "Deliberate MCP fixture failure")

func test_pending():
	pending("MCP fixture pending")

func test_pause():
	assert_true(true)
	pause_before_teardown()

func test_waiting():
	await get_tree().create_timer(3600).timeout
	assert_true(true)

func test_blocking():
	while true:
		pass

class TestInner extends GutTest:
	func test_inner_success():
		assert_true(true)
