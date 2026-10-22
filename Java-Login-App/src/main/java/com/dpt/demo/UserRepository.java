package com.dpt.demo;

import java.util.List;
import java.util.Optional;

import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Repository;

/**
 * Employee accounts. Every query is parameterised and passwords are stored as BCrypt hashes.
 */
@Repository
public class UserRepository {

	private final JdbcTemplate jdbc;

	private final PasswordEncoder passwordEncoder;

	public UserRepository(JdbcTemplate jdbc, PasswordEncoder passwordEncoder) {
		this.jdbc = jdbc;
		this.passwordEncoder = passwordEncoder;
	}

	public void create(String firstName, String lastName, String email, String username, String rawPassword)
			throws UsernameTakenException {
		try {
			jdbc.update("INSERT INTO Employee (first_name, last_name, email, username, password) VALUES (?, ?, ?, ?, ?)",
					firstName, lastName, email, username, passwordEncoder.encode(rawPassword));
		} catch (DuplicateKeyException ex) {
			throw new UsernameTakenException(username);
		}
	}

	public Optional<String> authenticate(String username, String rawPassword) {
		List<String> hashes = jdbc.queryForList("SELECT password FROM Employee WHERE username = ?", String.class,
				username);
		if (hashes.isEmpty() || !passwordEncoder.matches(rawPassword, hashes.get(0))) {
			return Optional.empty();
		}
		return Optional.of(username);
	}
}
