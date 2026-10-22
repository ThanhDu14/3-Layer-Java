package com.dpt.demo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.model;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.view;

import javax.servlet.Filter;
import javax.servlet.http.Cookie;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.DefaultMockMvcBuilder;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Sessions live in Redis so any Tomcat in the auto scaling group can serve any request.
 * The container disables CONFIG the way ElastiCache does.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Testcontainers
@Sql(statements = "DELETE FROM Employee")
class RedisSessionTest {

	@Container
	static final GenericContainer<?> REDIS = new GenericContainer<>("redis:7.2")
			.withCommand("redis-server", "--rename-command", "CONFIG", "\"\"")
			.withExposedPorts(6379);

	@DynamicPropertySource
	static void redisProperties(DynamicPropertyRegistry registry) {
		registry.add("spring.session.store-type", () -> "redis");
		registry.add("spring.redis.host", REDIS::getHost);
		registry.add("spring.redis.port", () -> REDIS.getMappedPort(6379));
	}

	@Autowired
	private MockMvc mvc;

	@Test
	void contextStartsWhenConfigCommandDisabled() {
		// Loading the context is the assertion: Spring Session must not call CONFIG.
	}

	@Test
	void sessionSurvivesInstanceSwap() throws Exception {
		mvc.perform(post("/register").with(csrf())
				.param("userName", "alice").param("password", "secret1"));
		Cookie sessionCookie = mvc.perform(post("/login").with(csrf())
				.param("userName", "alice").param("password", "secret1"))
				.andReturn().getResponse().getCookie("SESSION");
		assertThat(sessionCookie).as("SESSION cookie from Spring Session").isNotNull();

		// Command-line args, because builder .properties() are defaults that the test profile overrides.
		try (ConfigurableApplicationContext other = new SpringApplicationBuilder(MyWebAppApplication.class)
				.profiles("test")
				.run("--server.port=0", "--spring.session.store-type=redis",
						"--spring.redis.host=" + REDIS.getHost(),
						"--spring.redis.port=" + REDIS.getMappedPort(6379))) {
			DefaultMockMvcBuilder builder = MockMvcBuilders.webAppContextSetup((WebApplicationContext) other)
					.addFilters(other.getBean("springSessionRepositoryFilter", Filter.class));
			MockMvc otherInstance = builder.apply(springSecurity()).build();

			otherInstance.perform(get("/user").cookie(sessionCookie))
					.andExpect(view().name("user"))
					.andExpect(model().attribute("username", "alice"));
		}
	}
}
