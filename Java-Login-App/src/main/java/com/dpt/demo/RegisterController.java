package com.dpt.demo;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.servlet.ModelAndView;

@Controller
public class RegisterController {

	private final UserRepository users;

	public RegisterController(UserRepository users) {
		this.users = users;
	}

	@GetMapping("register")
	public ModelAndView registerForm() {
		return new ModelAndView("register");
	}

	@PostMapping("register")
	public ModelAndView register(String firstName, String lastName, String email, String userName, String password) {
		ModelAndView mv = new ModelAndView("register");
		if (isBlank(userName) || isBlank(password)) {
			mv.addObject("message", "Username and password are required");
			return mv;
		}
		try {
			users.create(firstName, lastName, email, userName, password);
			mv.addObject("message", "user account has been added for " + userName);
		} catch (UsernameTakenException ex) {
			mv.addObject("message", "Username already exists");
		}
		return mv;
	}

	private static boolean isBlank(String value) {
		return value == null || value.trim().isEmpty();
	}
}
