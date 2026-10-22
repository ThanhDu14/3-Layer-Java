package com.dpt.demo;

import java.util.Optional;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpSession;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.SessionAttribute;
import org.springframework.web.servlet.ModelAndView;

/**
 * Login state lives in the HTTP session (shared through Redis in production),
 * never in controller fields: controllers are singletons shared by every user.
 */
@Controller
public class LoginController {

	static final String SESSION_USERNAME = "username";

	private final UserRepository users;

	public LoginController(UserRepository users) {
		this.users = users;
	}

	@GetMapping("login")
	public ModelAndView loginForm() {
		return new ModelAndView("login");
	}

	@PostMapping("login")
	public ModelAndView login(String userName, String password, HttpServletRequest request) {
		Optional<String> user = users.authenticate(userName, password);
		if (!user.isPresent()) {
			ModelAndView mv = new ModelAndView("login");
			mv.addObject("errorMessage", "Invalid username or password");
			return mv;
		}
		request.getSession(true);
		request.changeSessionId();
		request.getSession().setAttribute(SESSION_USERNAME, user.get());
		return new ModelAndView("redirect:/user");
	}

	@GetMapping("user")
	public ModelAndView user(@SessionAttribute(name = SESSION_USERNAME, required = false) String username) {
		if (username == null) {
			return new ModelAndView("redirect:/login");
		}
		ModelAndView mv = new ModelAndView("user");
		mv.addObject("username", username);
		return mv;
	}

	@PostMapping("logout")
	public ModelAndView logout(HttpServletRequest request) {
		HttpSession session = request.getSession(false);
		if (session != null) {
			session.invalidate();
		}
		return new ModelAndView("redirect:/login");
	}
}
