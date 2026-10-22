package com.dpt.demo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.model;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.request;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.view;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Sql(statements = "DELETE FROM Employee")
class AuthFlowTest {

	@Autowired
	private MockMvc mvc;

	@Autowired
	private JdbcTemplate jdbc;

	private ResultActions register(String userName, String password) throws Exception {
		return mvc.perform(post("/register").with(csrf())
				.param("firstName", "First").param("lastName", "Last")
				.param("email", userName + "@example.com")
				.param("userName", userName).param("password", password));
	}

	private ResultActions login(String userName, String password) throws Exception {
		return mvc.perform(post("/login").with(csrf())
				.param("userName", userName).param("password", password));
	}

	private int employeeCount() {
		return jdbc.queryForObject("SELECT COUNT(*) FROM Employee", Integer.class);
	}

	@Test
	void registerStoresBcryptHashNotPlaintext() throws Exception {
		register("alice", "secret1")
				.andExpect(model().attribute("message", "user account has been added for alice"));

		String stored = jdbc.queryForObject(
				"SELECT password FROM Employee WHERE username = 'alice'", String.class);
		assertThat(stored).startsWith("$2").isNotEqualTo("secret1");
	}

	@Test
	void registerDuplicateUsernameShowsMessage() throws Exception {
		register("alice", "secret1");

		register("alice", "other")
				.andExpect(view().name("register"))
				.andExpect(model().attribute("message", "Username already exists"));
		assertThat(employeeCount()).isEqualTo(1);
	}

	@Test
	void registerBlankPasswordRejected() throws Exception {
		register("alice", "  ")
				.andExpect(model().attribute("message", "Username and password are required"));
		assertThat(employeeCount()).isZero();
	}

	@Test
	void loginSuccessRedirectsToUserAndSetsSession() throws Exception {
		register("alice", "secret1");

		login("alice", "secret1")
				.andExpect(redirectedUrl("/user"))
				.andExpect(request().sessionAttribute("username", "alice"));
	}

	@Test
	void wrongPasswordAfterAnotherUsersSuccessfulLoginIsRejected() throws Exception {
		register("alice", "secret1");
		register("bob", "secret2");
		login("alice", "secret1").andExpect(redirectedUrl("/user"));

		login("bob", "wrong")
				.andExpect(view().name("login"))
				.andExpect(model().attribute("errorMessage", "Invalid username or password"));
	}

	@Test
	void sqlInjectionLoginIsRejected() throws Exception {
		register("alice", "secret1");

		login("' OR '1'='1", "' OR '1'='1")
				.andExpect(view().name("login"))
				.andExpect(model().attribute("errorMessage", "Invalid username or password"));
	}

	@Test
	void userPageWithoutSessionRedirectsToLogin() throws Exception {
		mvc.perform(get("/user")).andExpect(redirectedUrl("/login"));
	}

	@Test
	void userPageWithSessionShowsUsername() throws Exception {
		register("alice", "secret1");
		MockHttpSession session = (MockHttpSession) login("alice", "secret1")
				.andReturn().getRequest().getSession(false);

		mvc.perform(get("/user").session(session))
				.andExpect(view().name("user"))
				.andExpect(model().attribute("username", "alice"));
	}

	@Test
	void logoutInvalidatesSession() throws Exception {
		register("alice", "secret1");
		MockHttpSession session = (MockHttpSession) login("alice", "secret1")
				.andReturn().getRequest().getSession(false);

		mvc.perform(post("/logout").with(csrf()).session(session))
				.andExpect(redirectedUrl("/login"));

		assertThat(session.isInvalid()).isTrue();
	}
}
