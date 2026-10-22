package com.dpt.demo;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.view;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class WebSecurityTest {

	@Autowired
	private MockMvc mvc;

	@Test
	void homePageIsPublic() throws Exception {
		mvc.perform(get("/")).andExpect(status().isOk()).andExpect(view().name("home"));
	}

	@Test
	void loginAndRegisterFormsArePublic() throws Exception {
		mvc.perform(get("/login")).andExpect(status().isOk());
		mvc.perform(get("/register")).andExpect(status().isOk());
	}

	@Test
	void postWithoutCsrfIsForbidden() throws Exception {
		mvc.perform(post("/login").param("userName", "a").param("password", "b"))
				.andExpect(status().isForbidden());
	}

	@Test
	void unknownPathIsDenied() throws Exception {
		mvc.perform(get("/admin")).andExpect(status().isForbidden());
	}
}
