package com.dpt.demo;

public class UsernameTakenException extends Exception {

	private static final long serialVersionUID = 1L;

	public UsernameTakenException(String username) {
		super("Username already exists: " + username);
	}
}
