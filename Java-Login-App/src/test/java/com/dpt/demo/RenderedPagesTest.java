package com.dpt.demo;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;

/** Renders the real JSPs in an embedded Tomcat, which MockMvc does not do. */
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
@Sql(statements = "DELETE FROM Employee")
class RenderedPagesTest {

	private static final Pattern CSRF = Pattern.compile("name=\"_csrf\" value=\"([^\"]+)\"");

	@Autowired
	private TestRestTemplate http;

	private static String firstGroup(Pattern pattern, String body) {
		Matcher m = pattern.matcher(body);
		assertThat(m.find()).as("pattern %s in page", pattern).isTrue();
		return m.group(1);
	}

	@Test
	void footerShowsVersionAndHost() {
		String body = http.getForObject("/", String.class);

		assertThat(firstGroup(Pattern.compile("id=\"app-version\">([^<]+)<"), body)).isNotBlank();
		assertThat(firstGroup(Pattern.compile("id=\"served-by\">([^<]+)<"), body)).isNotBlank();
	}

	@Test
	void usernameIsHtmlEscaped() {
		ResponseEntity<String> form = http.getForEntity("/register", String.class);
		String token = firstGroup(CSRF, form.getBody());
		String cookie = form.getHeaders().getFirst(HttpHeaders.SET_COOKIE).split(";", 2)[0];

		HttpHeaders headers = new HttpHeaders();
		headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);
		headers.add(HttpHeaders.COOKIE, cookie);
		MultiValueMap<String, String> params = new LinkedMultiValueMap<>();
		params.add("_csrf", token);
		params.add("userName", "<script>x</script>");
		params.add("password", "secret1");

		String body = http.postForObject("/register", new HttpEntity<>(params, headers), String.class);

		assertThat(body).doesNotContain("<script>x</script>").contains("&lt;script&gt;");
	}
}
