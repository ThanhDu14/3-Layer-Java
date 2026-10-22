package com.dpt.demo;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/**
 * The NLB health check must keep passing while the database is unreachable,
 * otherwise an RDS failover would pull every Tomcat out of the target group.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@TestPropertySource(properties = {
		"spring.datasource.url=jdbc:mysql://127.0.0.1:1/none",
		"spring.sql.init.mode=never" })
class HealthWithoutDatabaseTest {

	@Autowired
	private MockMvc mvc;

	@Test
	void healthLbIsUpWithoutDatabase() throws Exception {
		mvc.perform(get("/actuator/health/lb"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.status").value("UP"));
	}
}
